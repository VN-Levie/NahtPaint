import AppKit
import XCTest
@testable import PaintCore

/// Call the real AppKit handler in an isolated, never-shown window. No events are posted.
final class CanvasWheelZoomTests: XCTestCase {
    func testMouseWheelZoomsInAndOutAroundThePixelUnderThePointer() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            let pointer = Self.pointer(in: scroll)
            let originalPixel = Self.pixel(at: pointer, in: scroll)
            scroll.scrollWheel(with: try Self.wheel(y: 1, at: pointer))
            XCTAssertEqual(engine.zoom, 1.25, accuracy: 0.0001)
            Self.assertPoint(Self.pixel(at: pointer, in: scroll), equals: originalPixel)
            scroll.scrollWheel(with: try Self.wheel(y: -1, at: pointer))
            XCTAssertEqual(engine.zoom, 1, accuracy: 0.0001)
            Self.assertPoint(Self.pixel(at: pointer, in: scroll), equals: originalPixel)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testNaturalScrollingDoesNotReversePhysicalWheelZoomDirection() async {
        await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            let pointer = Self.pointer(in: scroll)
            // NSEvent exposes natural-scroll direction but CGEvent has no public setter for it.
            scroll.scrollWheel(with: InvertedWheelEvent(deltaY: -1, location: pointer))
            XCTAssertEqual(engine.zoom, 1.25, accuracy: 0.0001)
            scroll.scrollWheel(with: InvertedWheelEvent(deltaY: 1, location: pointer))
            XCTAssertEqual(engine.zoom, 1, accuracy: 0.0001)
        }
    }

    func testPreciseMouseWheelZoomsSmoothlyAndReversesWithoutMovingItsAnchor() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            let pointer = Self.pointer(in: scroll)
            let originalPixel = Self.pixel(at: pointer, in: scroll)
            let forward = try Self.wheel(y: 3, precise: true, at: pointer)
            XCTAssertTrue(forward.hasPreciseScrollingDeltas)
            XCTAssertTrue(forward.phase.isEmpty)
            scroll.scrollWheel(with: forward)
            XCTAssertGreaterThan(engine.zoom, 1)
            XCTAssertLessThan(engine.zoom, 1.25, "A small precise delta must be finer than a wheel notch")
            Self.assertPoint(Self.pixel(at: pointer, in: scroll), equals: originalPixel)
            scroll.scrollWheel(with: try Self.wheel(y: -3, precise: true, at: pointer))
            XCTAssertEqual(engine.zoom, 1, accuracy: 0.0001)
            Self.assertPoint(Self.pixel(at: pointer, in: scroll), equals: originalPixel)
        }
    }

    func testZoomClampsWithoutChangingPixelsHistoryOrDirtyState() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            let pixels = engine.bitmap.pixels
            let renderVersion = engine.renderVersion
            for (start, delta, expected): (CGFloat, Int32, CGFloat) in [(7.9, 1, 8), (8, 1, 8), (0.051, -1, 0.05), (0.05, -1, 0.05)] {
                engine.zoom = start
                scroll.updateCanvas()
                scroll.scrollWheel(with: try Self.wheel(y: delta, at: Self.pointer(in: scroll)))
                XCTAssertEqual(engine.zoom, expected, accuracy: 0.0001)
            }
            XCTAssertEqual(engine.width, 1600)
            XCTAssertEqual(engine.height, 1200)
            XCTAssertEqual(engine.bitmap.pixels, pixels)
            XCTAssertEqual(engine.renderVersion, renderVersion)
            XCTAssertFalse(engine.canUndo)
            XCTAssertFalse(engine.canRedo)
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testZoomPreservesFloatingSelectionAndEditableText() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            engine.insertText("Keep editable", at: CGPoint(x: 300, y: 250), width: 180)
            engine.commitSelection()
            engine.markSaved()
            engine.select(rect: CGRect(x: 280, y: 230, width: 240, height: 100))
            let text = try XCTUnwrap(engine.textObjects.first)
            let selection = try XCTUnwrap(engine.selection)
            let pixels = engine.bitmap.pixels
            let undoBefore = engine.canUndo
            let renderVersion = engine.renderVersion
            scroll.scrollWheel(with: try Self.wheel(y: 1, at: Self.pointer(in: scroll)))
            XCTAssertEqual(engine.zoom, 1.25, accuracy: 0.0001)
            XCTAssertEqual(engine.selection?.rect, selection.rect)
            XCTAssertEqual(engine.selection?.image.pixels, selection.image.pixels)
            XCTAssertEqual(engine.selection?.textIDs, selection.textIDs)
            XCTAssertEqual(engine.bitmap.pixels, pixels)
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(engine.textObjects.first?.id, text.id)
            XCTAssertEqual(engine.textObjects.first?.text, text.text)
            XCTAssertEqual(engine.textObjects.first?.bounds, text.bounds)
            XCTAssertEqual(engine.textObjects.first?.style, text.style)
            XCTAssertEqual(engine.canUndo, undoBefore)
            XCTAssertEqual(engine.renderVersion, renderVersion)
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testShiftHorizontalAndTrackpadScrollingDoNotZoom() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            let pointer = Self.pointer(in: scroll)
            let events = [
                try Self.wheel(y: 1, modifiers: .maskShift, at: pointer),
                try Self.wheel(y: 0, x: 1, at: pointer),
                try Self.wheel(y: 10, precise: true, phase: 2, at: pointer),
                try Self.wheel(y: 10, precise: true, momentum: 2, at: pointer)
            ]
            XCTAssertFalse(events[2].phase.isEmpty)
            XCTAssertFalse(events[3].momentumPhase.isEmpty)
            for event in events {
                scroll.scrollWheel(with: event)
                XCTAssertEqual(engine.zoom, 1, "Normal panning gestures must retain the current zoom")
            }
        }
    }

    func testCommandTrackpadGestureCanZoom() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            scroll.scrollWheel(with: try Self.wheel(y: 10, precise: true, phase: 2,
                                                    modifiers: .maskCommand, at: Self.pointer(in: scroll)))
            XCTAssertGreaterThan(engine.zoom, 1)
        }
    }

    func testWheelDoesNotZoomDuringDrawingOrMarqueeDrag() async throws {
        try await MainActor.run {
            for tool: PaintTool in [.pencil, .select] {
                let (engine, scroll, window) = Self.fixture()
                defer { window.contentView = nil }
                engine.tool = tool
                let pointer = Self.pointer(in: scroll)
                scroll.canvas.mouseDown(with: try Self.mouse(.leftMouseDown, at: pointer, window: window))
                scroll.scrollWheel(with: try Self.wheel(y: 1, at: pointer))
                XCTAssertEqual(engine.zoom, 1, "Changing scale midway through a drag would change image coordinates")
                scroll.canvas.mouseUp(with: try Self.mouse(.leftMouseUp, at: pointer, window: window))
                scroll.scrollWheel(with: try Self.wheel(y: 1, at: pointer))
                XCTAssertEqual(engine.zoom, 1.25, accuracy: 0.0001)
            }
        }
    }

    func testWheelDoesNotCancelOrZoomDuringCanvasExpansion() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture()
            defer { window.contentView = nil }
            let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == .right })
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            handle.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, window: window))
            scroll.scrollWheel(with: try Self.wheel(y: 1, at: Self.pointer(in: scroll)))
            XCTAssertEqual(engine.zoom, 1)
            XCTAssertTrue(scroll.board.isExpanding)
            XCTAssertEqual(engine.width, 1600)
            scroll.board.cancelExpansion()
            XCTAssertFalse(engine.canUndo)
        }
    }

    @MainActor private static func fixture() -> (PaintEngine, CanvasScrollView, NSWindow) {
        _ = NSApplication.shared
        let engine = PaintEngine(width: 1600, height: 1200)
        let scroll = CanvasScrollView(engine: engine)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        scroll.layoutSubtreeIfNeeded()
        scroll.updateCanvas()
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (engine, scroll, window)
    }

    @MainActor private static func pointer(in scroll: CanvasScrollView) -> CGPoint {
        scroll.contentView.convert(CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY), to: nil)
    }

    @MainActor private static func pixel(at pointer: CGPoint, in scroll: CanvasScrollView) -> CGPoint {
        let local = scroll.canvas.convert(pointer, from: nil)
        return CGPoint(x: local.x / scroll.canvas.engine.zoom, y: local.y / scroll.canvas.engine.zoom)
    }

    private static func assertPoint(_ actual: CGPoint, equals expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.01, file: file, line: line)
    }

    @MainActor private static func wheel(y: Int32, x: Int32 = 0, precise: Bool = false, phase: Int64 = 0,
                                         momentum: Int64 = 0, modifiers: CGEventFlags = [], at point: CGPoint) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                          wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.flags = modifiers
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        // A CGEvent without a target window uses screen coordinates. Map its AppKit
        // location to our isolated window's local point before invoking the handler.
        event.location = .zero
        let origin = try XCTUnwrap(NSEvent(cgEvent: event)).locationInWindow
        event.location = CGPoint(x: point.x - origin.x, y: origin.y - point.y)
        let result = try XCTUnwrap(NSEvent(cgEvent: event))
        assertPoint(result.locationInWindow, equals: point)
        return result
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
}

private final class InvertedWheelEvent: NSEvent {
    private let wheelDeltaY: CGFloat
    private let wheelLocation: CGPoint
    init(deltaY: CGFloat, location: CGPoint) {
        wheelDeltaY = deltaY
        wheelLocation = location
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaY: CGFloat { wheelDeltaY }
    override var scrollingDeltaX: CGFloat { 0 }
    override var locationInWindow: NSPoint { wheelLocation }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}
