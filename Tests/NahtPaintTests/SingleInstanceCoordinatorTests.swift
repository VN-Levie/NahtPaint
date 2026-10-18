import Foundation
import XCTest
@testable import NahtPaint

final class SingleInstanceCoordinatorTests: XCTestCase {
    func testLockExcludesOtherOpenersAndReleasesWithoutDeletingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first = try SingleInstanceLock.acquire(at: url, processIdentifier: 101)
        XCTAssertNotNil(first)
        XCTAssertEqual(SingleInstanceLock.ownerPID(at: url), 101)
        XCTAssertNil(try SingleInstanceLock.acquire(at: url, processIdentifier: 202))
        XCTAssertEqual(SingleInstanceLock.ownerPID(at: url), 101)
        first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let replacement = try SingleInstanceLock.acquire(at: url, processIdentifier: 202)
        XCTAssertNotNil(replacement)
        XCTAssertEqual(SingleInstanceLock.ownerPID(at: url), 202)
        withExtendedLifetime(replacement) {}
    }

    func testStalePIDDoesNotPreventAcquiringLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        try Data("999999\n".utf8).write(to: url)
        XCTAssertNil(SingleInstanceLock.ownerPID(at: url))
        let lock = try SingleInstanceLock.acquire(at: url, processIdentifier: 101)
        XCTAssertNotNil(lock)
        XCTAssertEqual(SingleInstanceLock.ownerPID(at: url), 101)
        withExtendedLifetime(lock) {}
    }

    func testLockRejectsSymlinkWithoutChangingTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let url = directory.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try SingleInstanceLock.acquire(at: url))
        XCTAssertNil(SingleInstanceLock.ownerPID(at: url))
        XCTAssertEqual(try String(contentsOf: target), "keep")
    }

    func testKnownPreviewAndReleaseBuildsShareOneProductFamily() {
        let current = instance(30, "com.levie.NathPaint", 30)
        let preview = instance(20, "com.levie.NathPaint.WheelZoomPreview", 20)
        let olderPreview = instance(10, "com.levie.NathPaint.ReadmePreview", 10)
        let unrelated = instance(1, "com.levie.NathPaint.OtherApp", 1)
        XCTAssertEqual(RunningPaintInstance.olderInstance(in: [current, preview, unrelated, olderPreview], than: current), olderPreview)
    }

    func testConcurrentLaunchesHaveOneDeterministicOlderCandidate() {
        let first = instance(20, "com.levie.NathPaint", 30)
        let second = instance(30, "com.levie.NathPaint.FeaturePreview", 30)
        XCTAssertNil(RunningPaintInstance.olderInstance(in: [first, second], than: first))
        XCTAssertEqual(RunningPaintInstance.olderInstance(in: [first, second], than: second), first)
        let launchedLaterWithLowerPID = instance(1, "com.levie.NathPaint", 40)
        XCTAssertNil(RunningPaintInstance.olderInstance(in: [first, launchedLaterWithLowerPID], than: first))
    }

    func testSharedInstanceGroupRecognizesFutureVariantsWithoutMatchingUnrelatedApps() {
        let current = instance(30, "com.levie.NathPaint", 30)
        let variant = RunningPaintInstance(processIdentifier: 20, bundleIdentifier: "com.levie.FuturePaintPreview",
                                          launchDate: Date(timeIntervalSince1970: 20), instanceGroup: "com.levie.NathPaint")
        let unrelated = RunningPaintInstance(processIdentifier: 10, bundleIdentifier: "com.levie.FuturePaintPreview",
                                            launchDate: Date(timeIntervalSince1970: 10), instanceGroup: "com.levie.OtherApp")
        XCTAssertEqual(RunningPaintInstance.olderInstance(in: [unrelated, variant, current], than: current), variant)
        XCTAssertNil(RunningPaintInstance.olderInstance(in: [unrelated, current], than: current))
    }

    func testRequestRoundTripPreservesOnlyLocalFileURLs() async {
        await MainActor.run {
            let request = SingleInstanceCoordinator.Request.openURLs([URL(fileURLWithPath: "/tmp/example image.png")])
            XCTAssertEqual(SingleInstanceCoordinator.Request(payload: request.payload), request)
            XCTAssertEqual(SingleInstanceCoordinator.Request(payload: ["action": "showWindow"]), .showWindow)
            XCTAssertNil(SingleInstanceCoordinator.Request(payload: ["action": "openURLs", "urls": ["https://example.com/picture.png"]]))
            XCTAssertNil(SingleInstanceCoordinator.Request(payload: ["action": "openURLs", "urls": ["file://remote-host/image.png"]]))
            XCTAssertNil(SingleInstanceCoordinator.Request(payload: ["action": "openURLs", "urls": []]))
            XCTAssertNil(SingleInstanceCoordinator.Request(payload: ["action": "unknown"]))
        }
    }

    private func instance(_ pid: Int32, _ identifier: String, _ date: TimeInterval) -> RunningPaintInstance {
        RunningPaintInstance(processIdentifier: pid, bundleIdentifier: identifier, launchDate: Date(timeIntervalSince1970: date))
    }
}
