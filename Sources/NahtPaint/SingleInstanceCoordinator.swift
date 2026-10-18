import AppKit
import Darwin

/// A kernel lock is the authority; the PID only identifies its current owner.
/// Keep the file in place: unlinking it would allow two processes to lock different inodes.
final class SingleInstanceLock {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(at url: URL, processIdentifier: pid_t = getpid()) throws -> SingleInstanceLock? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        var ownsDescriptor = false
        defer { if !ownsDescriptor { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EACCES)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw posixError()
        }
        let data = Data("\(processIdentifier)\n".utf8)
        guard ftruncate(descriptor, 0) == 0 else { throw posixError() }
        let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == data.count else { throw posixError() }
        ownsDescriptor = true
        return SingleInstanceLock(descriptor: descriptor)
    }

    static func ownerPID(at url: URL) -> pid_t? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // A PID left on disk after exit is not a live protocol endpoint.
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return nil }
        guard errno == EWOULDBLOCK else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 1, count < bytes.count,
              let value = String(bytes: bytes.prefix(count), encoding: .utf8),
              value.hasSuffix("\n"), let pid = pid_t(value.dropLast()), pid > 0 else { return nil }
        return pid
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct RunningPaintInstance: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let launchDate: Date?
    let instanceGroup: String?

    init(processIdentifier: pid_t, bundleIdentifier: String?, launchDate: Date?, instanceGroup: String? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
        self.instanceGroup = instanceGroup
    }

    static let productGroup = "com.levie.NathPaint"

    static let productIdentifiers: Set<String> = [
        "com.levie.NathPaint", "com.levie.NathPaint.FeaturePreview",
        "com.levie.NathPaint.WheelZoomPreview", "com.levie.NathPaint.ReadmePreview"
    ]

    var isProductInstance: Bool {
        instanceGroup == Self.productGroup || bundleIdentifier.map(Self.productIdentifiers.contains) == true
    }

    static func olderInstance(in applications: [Self], than current: Self) -> Self? {
        applications.filter {
            guard $0.processIdentifier != current.processIdentifier, $0.isProductInstance else { return false }
            return precedes($0, current)
        }.min(by: precedes)
    }

    private static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        let left = lhs.launchDate ?? .distantFuture
        let right = rhs.launchDate ?? .distantFuture
        if left != right { return left < right }
        return lhs.processIdentifier < rhs.processIdentifier
    }
}

@MainActor
protocol SingleInstanceCoordinating: AnyObject {
    var isPrimary: Bool { get }
    var onRequest: ((SingleInstanceCoordinator.Request) -> Void)? { get set }
    func start() throws -> Bool
    func forward(_ request: SingleInstanceCoordinator.Request, completion: @escaping (Bool) -> Void)
    func invalidate()
}

@MainActor
final class SingleInstanceCoordinator: NSObject, SingleInstanceCoordinating {
    enum Request: Equatable {
        case showWindow
        case openURLs([URL])

        var payload: [String: Any] {
            switch self {
            case .showWindow: return ["action": "showWindow"]
            case .openURLs(let urls): return ["action": "openURLs", "urls": urls.map(\.absoluteString)]
            }
        }

        init?(payload: [AnyHashable: Any]) {
            switch payload["action"] as? String {
            case "showWindow": self = .showWindow
            case "openURLs":
                guard let values = payload["urls"] as? [String], !values.isEmpty else { return nil }
                let urls = values.compactMap(URL.init(string:))
                guard urls.count == values.count,
                      urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }) else { return nil }
                self = .openURLs(urls)
            default: return nil
            }
        }
    }

    private static let requestName = Notification.Name("com.levie.NathPaint.instanceRequest")
    private static let acknowledgementName = Notification.Name("com.levie.NathPaint.instanceAccepted")
    private let lockURL: URL
    private var lock: SingleInstanceLock?
    private var targetPID: pid_t?
    private var observing = false
    private var queuedRequests: [Request] = []
    private var pendingAcknowledgements: [String: (Bool) -> Void] = [:]
    private(set) var isPrimary = false
    var onRequest: ((Request) -> Void)? {
        didSet {
            guard let onRequest else { return }
            let requests = queuedRequests
            queuedRequests.removeAll()
            requests.forEach(onRequest)
        }
    }

    init(lockURL: URL? = nil) {
        self.lockURL = lockURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.levie.NathPaint", isDirectory: true)
            .appendingPathComponent("instance.lock")
        super.init()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    /// Call before creating the status item. A false result has no document/UI state to preserve.
    func start() throws -> Bool {
        if isPrimary { return true }
        if targetPID != nil { return false }
        installObservers()
        let current = Self.snapshot(NSRunningApplication.current)
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && kill($0.processIdentifier, 0) == 0
        }
        if let existing = RunningPaintInstance.olderInstance(in: applications.map(Self.snapshot), than: current),
           kill(existing.processIdentifier, 0) == 0 {
            targetPID = existing.processIdentifier
            return false
        }
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock = try SingleInstanceLock.acquire(at: lockURL)
        isPrimary = lock != nil
        if !isPrimary { targetPID = SingleInstanceLock.ownerPID(at: lockURL) }
        return isPrimary
    }

    /// Completion reports whether the other process accepted the request; this never quits either process.
    func forward(_ request: Request, completion: @escaping (Bool) -> Void) {
        guard !isPrimary, Request(payload: request.payload) != nil else { completion(false); return }
        forward(request, attemptsRemaining: 10, completion: completion)
    }

    private func forward(_ request: Request, attemptsRemaining: Int, completion: @escaping (Bool) -> Void) {
        let ownerPID = SingleInstanceLock.ownerPID(at: lockURL)
        // The atomic owner takes precedence over the earlier discovery snapshot.
        // Unbundled development launches also participate in this same-user lock/protocol.
        if let ownerPID, ownerPID != getpid(), kill(ownerPID, 0) == 0 {
            targetPID = ownerPID
            let requestID = UUID().uuidString
            pendingAcknowledgements[requestID] = completion
            var payload = request.payload
            payload["requestID"] = requestID
            payload["replyTo"] = Self.address(getpid())
            DistributedNotificationCenter.default().postNotificationName(Self.requestName,
                object: Self.address(ownerPID), userInfo: payload, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.pendingAcknowledgements.removeValue(forKey: requestID)?(false)
            }
        } else if attemptsRemaining > 0 {
            // An older launch may still be installing the observer and publishing its PID.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.forward(request, attemptsRemaining: attemptsRemaining - 1, completion: completion)
            }
        } else {
            guard let pid = targetPID, let application = NSRunningApplication(processIdentifier: pid),
                  !application.isTerminated, Self.snapshot(application).isProductInstance else {
                completion(false)
                return
            }
            switch request {
            case .showWindow:
                completion(application.activate(options: [.activateAllWindows]))
            case .openURLs(let urls):
                guard let bundleURL = application.bundleURL else { completion(false); return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: configuration) { _, error in
                    DispatchQueue.main.async { completion(error == nil) }
                }
            }
        }
    }

    func invalidate() {
        DistributedNotificationCenter.default().removeObserver(self)
        observing = false
        lock = nil
        isPrimary = false
        targetPID = nil
        queuedRequests.removeAll()
        let completions = Array(pendingAcknowledgements.values)
        pendingAcknowledgements.removeAll()
        completions.forEach { $0(false) }
    }

    private func installObservers() {
        guard !observing else { return }
        observing = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(receiveRequest(_:)), name: Self.requestName,
                           object: Self.address(getpid()), suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(receiveAcknowledgement(_:)), name: Self.acknowledgementName,
                           object: Self.address(getpid()), suspensionBehavior: .deliverImmediately)
    }

    @objc private func receiveRequest(_ notification: Notification) {
        guard isPrimary, let payload = notification.userInfo, let request = Request(payload: payload),
              let requestID = payload["requestID"] as? String,
              let replyTo = payload["replyTo"] as? String else { return }
        // A file-open error may show a modal alert. Acknowledge receipt before running
        // UI work so the sender doesn't time out while the user handles that alert.
        if let onRequest { DispatchQueue.main.async { onRequest(request) } }
        else { queuedRequests.append(request) }
        DistributedNotificationCenter.default().postNotificationName(Self.acknowledgementName,
            object: replyTo, userInfo: ["requestID": requestID], deliverImmediately: true)
    }

    @objc private func receiveAcknowledgement(_ notification: Notification) {
        guard let requestID = notification.userInfo?["requestID"] as? String else { return }
        pendingAcknowledgements.removeValue(forKey: requestID)?(true)
    }

    private static func address(_ pid: pid_t) -> String { "\(geteuid()).\(pid)" }
    private static func snapshot(_ application: NSRunningApplication) -> RunningPaintInstance {
        RunningPaintInstance(processIdentifier: application.processIdentifier,
                             bundleIdentifier: application.bundleIdentifier, launchDate: application.launchDate,
                             instanceGroup: application.bundleURL.flatMap(Bundle.init(url:))?
                                .object(forInfoDictionaryKey: "NahtPaintInstanceGroup") as? String)
    }
}
