import Foundation
import AppKit

/// Manages the on-disk archive: the SQLite file and lossless original images.
/// Images are copied verbatim (never re-encoded) into `images/<letterId>/<index>.<ext>`;
/// the `page` table stores the path relative to `root`.
public struct ImageStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Combray`.
    /// `~/Documents/Combray` — a plain, Finder-browsable, backup-friendly folder.
    public static func defaultRoot() -> URL {
        let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Combray", isDirectory: true)
    }

    public var lettersDir: URL { root.appendingPathComponent("letters", isDirectory: true) }
    public var databaseURL: URL { root.appendingPathComponent("combray.sqlite") }

    /// Copies a page image (losslessly — original bytes, original extension) into a Finder-browsable,
    /// logically named location and returns its `Page`.
    /// e.g. `~/Documents/Combray/letters/3/letter_3_page_1.jpg` — openable directly in Preview.
    public func importImage(from source: URL, letterId: String, letterNumber: Int, index: Int) throws -> Page {
        let dir = lettersDir.appendingPathComponent("\(letterNumber)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let name = "letter_\(letterNumber)_page_\(index + 1).\(ext)"
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)

        var width: Int?
        var height: Int?
        if let image = NSImage(contentsOf: dest), let rep = image.representations.first {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        }

        return Page(
            letterId: letterId,
            pageIndex: index,
            imagePath: "letters/\(letterNumber)/\(name)",
            width: width,
            height: height
        )
    }

    /// Absolute URL for a stored page image.
    public func url(for page: Page) -> URL {
        root.appendingPathComponent(page.imagePath)
    }
}
