# NathPaint

A small native macOS paint app inspired by the direct, familiar workflow of Windows XP Paint. SwiftUI supplies the interface; AppKit and Core Graphics handle the pixel canvas, text editing, clipboard and menu bar. No third-party runtime dependencies.

## Build and run

Requires macOS 14 or later and Xcode with Swift 6 or later. The package uses Swift 5 language mode.

```sh
./scripts/build-app.sh
open build/NathPaint.app
```

Open `Package.swift` in Xcode to work on the app. `swift run NathPaint` also runs the editor, but the bundled `.app` provides the proper Dock icon and Finder integration.

```sh
swift test
```

## Quick workflow

1. Copy an image, open NathPaint and press **⌘V**. The first paste sizes a new canvas to the image's actual pixels.
2. Draw, type, select, move, resize or crop. Paste more images to build a composition.
3. Choose **Copy Image** (**⇧⌘C**) to put the entire result on the clipboard, ready to paste into another app. **⌘C** copies the current selection, or the full image if nothing is selected.

Use **Return** to place a floating selection and **Escape** to cancel it. Text is edited directly on the canvas; **⌘Return** finishes typing. Ordinary copy/paste shortcuts edit text while its editor has focus. Committed text becomes pixels, like classic Paint.

## Tools and files

- Rectangular selection with drag, corner resizing, arrow-key nudging, cut, copy, delete and crop.
- Pencil, brush, eraser, flood fill, eyedropper, text, line, rectangle and ellipse. Pencil/brush/eraser show the actual stroke footprint under the pointer, scaled with zoom.
- Tool shortcuts: **P** pencil, **B** brush, **E** eraser, **C** crop, **M** select, **T** text, **G** fill, **I** eyedropper, **L** line, **R** rectangle, **O** ellipse. Tool letters are inactive while entering text.
- Crop tool: drag a crop area and press Return to apply; Escape cancels.
- Inline text with independent color, size, optional border and optional background color. The bottom palette changes text color when the Text tool is active.
- Preset and custom colors, brush width, text size, shape fill and zoom.
- Image resizing and canvas sizing through the Image menu.
- Image-file drag and drop, Open, Save and Save As. PNG retains alpha; JPEG composites transparency onto white.
- Bounded undo/redo history. Quit/New/Open prompt for unsaved changes.

The first version edits one document at a time. It is a raster editor: no layers or editable project format. Changes stay local. Closing the window keeps the current document in memory; choose **Quit NathPaint** to exit. There is no recovery after a forced termination, so save important work.

## Menu bar and preferences

**Settings** (**⌘,**) controls:

- **Show NathPaint in:** Dock + menu bar, Dock only, or Menu bar only.
- **Quick Open:** Double-click (default: single-click shows menu), Single-click (right-click shows menu), or Menu only.
- **Appearance:** System (default), Light, or Dark. Only the interface changes; a new canvas stays white and existing image pixels retain their colors.
- **Language:** English (default), Vietnamese, Simplified Chinese, Japanese, or System. System follows the supported preferred macOS language and falls back to English.

Preferences persist across launches. In double-click mode the single-click menu waits for the system double-click interval, so it does not interrupt the second click. In Dock-only mode the Dock icon reopens the hidden editor.

## Artwork

The app logo was created with the built-in ImageGen tool and packaged as a macOS icon. `Resources/logo-prompt.txt` records the final prompt. To rebuild the icon sizes:

```sh
./scripts/make-icon.sh
```

## Distribution

`build-app.sh` creates a local ad-hoc signed app for the current Mac architecture. This is suitable for local use and development; a public release would additionally need a Developer ID signature and Apple notarization. Build output and local preferences are excluded from Git.
