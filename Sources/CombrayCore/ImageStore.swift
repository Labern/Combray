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

    /// `~/Library/Application Support/Combray` — a plain, Finder-browsable folder that macOS does
    /// NOT gate behind a privacy prompt (unlike `~/Documents`), so the app never has to ask for
    /// permission. Still the source of truth: `Letters/<n>/` folders + `combray.sqlite`.
    public static func defaultRoot() -> URL {
        // Override hook for screenshot/testing runs (a seeded sample archive) — normal launches
        // never set this.
        if let override = ProcessInfo.processInfo.environment["COMBRAY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Combray", isDirectory: true)
    }

    /// One-time migration: the archive used to live in `~/Documents/Combray`, which macOS guards with
    /// a "would like to access Documents" prompt on every relaunch. Move it into Application Support
    /// (ungated) so the prompt never appears again. No-op once moved.
    public static func migrateFromDocumentsIfNeeded() {
        let fm = FileManager.default
        let new = defaultRoot()
        guard !fm.fileExists(atPath: new.path) else { return }
        let oldDocs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Combray", isDirectory: true)
        guard fm.fileExists(atPath: oldDocs.path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: oldDocs, to: new)
    }

    public var lettersDir: URL { root.appendingPathComponent("Letters", isDirectory: true) }
    public var databaseURL: URL { root.appendingPathComponent("combray.sqlite") }

    /// Copies a page image (losslessly — original bytes, original extension) into a Finder-browsable,
    /// logically named location and returns its `Page`.
    /// e.g. `~/Documents/Combray/Letters/3/letter_3_page_1.jpg` — openable directly in Preview.
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
            imagePath: "Letters/\(letterNumber)/\(name)",
            width: width,
            height: height
        )
    }

    /// Absolute URL for a stored page image.
    public func url(for page: Page) -> URL {
        root.appendingPathComponent(page.imagePath)
    }
}
