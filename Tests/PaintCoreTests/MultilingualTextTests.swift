import AppKit
import CoreText
import XCTest
@testable import PaintCore

/// Mixed Unicode paste, shaping and editing checks. These do not switch input sources or claim IME typing coverage.
final class MultilingualTextTests: XCTestCase {
    private static let lines: [(String, String)] = [
        ("Vietnamese", "Tiếng Việt: Xin chào! Tôi đang vẽ một bức tranh đẹp."),
        ("Vietnamese NFD", "Tiếng Việt NFD: Xin chào! Tiếng Việt có dấu: ắ ằ ẵ ặ ế ề ễ ệ.".decomposedStringWithCanonicalMapping),
        ("English", "English: The quick brown fox jumps over the lazy dog."),
        ("French", "Français : Un café crème, une élève et un cœur heureux."),
        ("Italian", "Italiano: Città, caffè, perché, così, però e virtù."),
        ("Chinese", "中文：你好！今天我们一起画一幅美丽的画。"),
        ("Korean", "한국어: 안녕하세요! 오늘은 아름다운 그림을 그립니다."),
        ("Thai", "ไทย: สวัสดี! วันนี้เราวาดภาพสวย ๆ ด้วยกัน"),
        ("Khmer", "ខ្មែរ: សួស្តី! ថ្ងៃនេះយើងគូររូបភាពស្អាតជាមួយគ្នា។"),
        ("Lao", "ລາວ: ສະບາຍດີ! ມື້ນີ້ພວກເຮົາແຕ້ມຮູບສວຍງາມ."),
        ("Japanese", "日本語：こんにちは！今日は美しい絵を描きます。")
    ]
    private static var sample: String { lines.map(\.1).joined(separator: "\n") }
    private static var artifactDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/multilingual-test", isDirectory: true)
    }

    func testMixedScriptObjectPreservesScalarsIdentityLayoutAndCancel() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 1000, height: 900)
            engine.fontSize = 24
            engine.insertText(Self.sample, at: CGPoint(x: 28, y: 28), width: 944)
            let original = try XCTUnwrap(engine.textObjects.first)
            Self.assertScalars(original.text, Self.sample)
            XCTAssertTrue(original.bounds.maxY < CGFloat(engine.height), "The fixture must fit fully within the canvas")
            engine.commitSelection()
            engine.markSaved()
            engine.selectText(id: original.id)
            XCTAssertEqual(engine.selectedTextID, original.id)
            let reopened = try XCTUnwrap(engine.beginTextEditing(id: original.id))
            Self.assertScalars(reopened.text, Self.sample)
            engine.updateText(id: original.id, text: reopened.text, layoutWidth: reopened.layoutWidth)
            let unchanged = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(unchanged.id, original.id)
            XCTAssertEqual(unchanged.bounds, original.bounds)
            XCTAssertEqual(unchanged.style, original.style)
            XCTAssertEqual(unchanged.raster.pixels, original.raster.pixels, "Reopening mixed text must not alter shaping or line wrapping")
            XCTAssertFalse(engine.isDirty)

            let edited = Self.sample.replacingOccurrences(of: "The quick brown fox jumps over the lazy dog.",
                                                          with: "Drawing and sharing one multilingual text box.")
            XCTAssertNotNil(engine.beginTextEditing(id: original.id))
            engine.updateText(id: original.id, text: edited, layoutWidth: original.layoutWidth)
            let changed = try XCTUnwrap(engine.textObjects.first)
            Self.assertScalars(changed.text, edited)
            XCTAssertEqual(changed.id, original.id)
            XCTAssertEqual(changed.position, original.position)
            XCTAssertEqual(changed.layoutWidth, original.layoutWidth)
            XCTAssertEqual(changed.style, original.style)
            engine.undo()
            Self.assertScalars(try XCTUnwrap(engine.textObjects.first).text, Self.sample)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.raster.pixels, original.raster.pixels)

            XCTAssertNotNil(engine.beginTextEditing(id: original.id))
            engine.fontSize = 32
            engine.textColor = .systemRed
            engine.cancelTextEditing()
            let cancelled = try XCTUnwrap(engine.textObjects.first)
            Self.assertScalars(cancelled.text, Self.sample)
            XCTAssertEqual(cancelled.id, original.id)
            XCTAssertEqual(cancelled.bounds, original.bounds)
            XCTAssertEqual(cancelled.style, original.style)
            XCTAssertEqual(cancelled.raster.pixels, original.raster.pixels)
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testMixedScriptClipboardMetadataAndPNGKeepTextAndRenderedPixels() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let source = PaintEngine(width: 1000, height: 900)
            source.fontSize = 24
            source.insertText(Self.sample, at: CGPoint(x: 28, y: 28), width: 944)
            let original = try XCTUnwrap(source.textObjects.first)
            let board = NSPasteboard(name: .init("NathPaintTests.Multilingual.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            try source.copy(to: board, entireCanvas: true)
            let metadata = try XCTUnwrap(board.data(forType: .init("com.nathpaint.editable-text.v1")))
            let transfers = try JSONDecoder().decode([PaintTextTransfer].self, from: metadata)
            Self.assertScalars(try XCTUnwrap(transfers.first).text, Self.sample)

            let pasted = PaintEngine(width: 1000, height: 900)
            pasted.paste(from: board)
            pasted.commitSelection()
            let restored = try XCTUnwrap(pasted.textObjects.first)
            Self.assertScalars(restored.text, Self.sample)
            XCTAssertEqual(restored.position, original.position)
            XCTAssertEqual(restored.layoutWidth, original.layoutWidth)
            XCTAssertEqual(restored.style, original.style)
            XCTAssertEqual(restored.raster.pixels, original.raster.pixels, "The private clipboard metadata must reproduce the same multilingual glyphs")
            let exported = try source.exportPNG()
            let copiedPNG = try XCTUnwrap(board.data(forType: .png))
            XCTAssertEqual(try Bitmap(image: XCTUnwrap(NSImage(data: copiedPNG))).pixels,
                           try Bitmap(image: XCTUnwrap(NSImage(data: exported))).pixels)
            XCTAssertEqual(try Bitmap(image: XCTUnwrap(NSImage(data: pasted.exportPNG()))).pixels,
                           try Bitmap(image: XCTUnwrap(NSImage(data: exported))).pixels)
            XCTAssertEqual(source.textObjects.first?.id, original.id, "PNG export must keep the original text object editable")
            try FileManager.default.createDirectory(at: Self.artifactDirectory, withIntermediateDirectories: true)
            try Self.sample.write(to: Self.artifactDirectory.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
            try exported.write(to: Self.artifactDirectory.appendingPathComponent("render.png"), options: .atomic)
        }
    }

    func testSystemFontFallbackShapesEveryRepresentativeScriptWithoutMissingGlyphs() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var fallbackFonts: [String: [String]] = [:]
            for (language, text) in Self.lines {
                let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
                let line = CTLineCreateWithAttributedString(attributed)
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                XCTAssertFalse(runs.isEmpty, language)
                var names = Set<String>()
                for run in runs {
                    let count = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let font = try XCTUnwrap(attributes[kCTFontAttributeName]) as! CTFont
                    names.insert(CTFontCopyPostScriptName(font) as String)
                    XCTAssertFalse(glyphs.contains(0), "Missing glyph in \(language), fallback font \(CTFontCopyPostScriptName(font))")
                }
                XCTAssertGreaterThan(CTLineGetTypographicBounds(line, nil, nil, nil), 0, language)
                fallbackFonts[language] = names.sorted()
            }
            try FileManager.default.createDirectory(at: Self.artifactDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fallbackFonts).write(to: Self.artifactDirectory.appendingPathComponent("fallback-fonts.json"), options: .atomic)
        }
    }

    func testNativePastedMixedTextGrowsPastTwoHundredPixelsAndReopensWithoutClipping() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 1000, height: 900)
            engine.fontSize = 24
            let view = NativePaintView(engine: engine)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 1000, height: 900)
            window.makeFirstResponder(view)
            defer { engine.finishEditing(); window.contentView = nil }
            let board = NSPasteboard(name: .init("NathPaintTests.MultilingualNative.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString(Self.sample, forType: .string)
            engine.paste(from: board)
            let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            Self.assertScalars(editor.string, Self.sample)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertGreaterThan(editor.frame.height, 200, "The native editor must grow beyond the old 200px initial height")
            try Self.assertWholeEditorFits(editor, canvas: view)

            let extended = Self.sample + "\nEnglish: Added after pasting. H"
            editor.insertText("\nEnglish: Added after pasting. ", replacementRange: editor.selectedRange())
            editor.insertText("H", replacementRange: editor.selectedRange())
            XCTAssertEqual(engine.tool, .text, "An H inserted into the text editor must not select the highlighter")
            Self.assertScalars(editor.string, extended)
            try Self.assertWholeEditorFits(editor, canvas: view)
            engine.finishEditing()
            let original = try XCTUnwrap(engine.textObjects.first)
            Self.assertScalars(original.text, extended)
            engine.tool = .select
            let point = view.convert(CGPoint(x: original.bounds.minX + 5, y: original.bounds.minY + 5), to: nil)
            let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 2, pressure: 1))
            view.mouseDown(with: doubleClick)
            let reopened = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            Self.assertScalars(reopened.string, extended)
            XCTAssertEqual(engine.editingTextID, original.id)
            XCTAssertEqual(reopened.font?.pointSize, original.style.fontSize)
            try Self.assertWholeEditorFits(reopened, canvas: view)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            reopened.keyDown(with: escape)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            Self.assertScalars(try XCTUnwrap(engine.textObjects.first).text, extended)
            XCTAssertFalse(window.isVisible, "The test must never show or activate its isolated window")
        }
    }

    @MainActor private static func assertWholeEditorFits(_ editor: NSTextView, canvas: NSView,
                                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(editor.layoutManager, file: file, line: line)
        let container = try XCTUnwrap(editor.textContainer, file: file, line: line)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        XCTAssertLessThanOrEqual(used.maxY + editor.textContainerInset.height * 2, editor.bounds.height + 1,
                                 "Multiline glyphs must fit inside the actual editable view", file: file, line: line)
        XCTAssertLessThanOrEqual(editor.frame.maxY, canvas.bounds.maxY + 1, file: file, line: line)
        let glyphs = layout.glyphRange(for: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        XCTAssertEqual(NSMaxRange(characters), (editor.string as NSString).length,
                       "Layout must include every character including final script lines", file: file, line: line)
    }

    private static func assertScalars(_ actual: String, _ expected: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        // Swift String equality is normalization-insensitive; scalar comparison catches accidental NFC/NFD rewrites.
        XCTAssertEqual(actual.unicodeScalars.map(\.value), expected.unicodeScalars.map(\.value), file: file, line: line)
    }
}
