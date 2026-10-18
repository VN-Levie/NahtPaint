import AppKit

/// Serialize background compression so obsolete measurements cannot pile up in parallel.
actor PNGSizeEncoder {
    static let shared = PNGSizeEncoder()

    func byteCount(of bitmap: Bitmap) -> Int? {
        guard !Task.isCancelled else { return nil }
        return try? bitmap.encoded(.png).count
    }
}
