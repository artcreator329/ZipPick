import Foundation

struct ArchiveEntry {
    /// Cleaned path components (no empty, "." or ".." parts).
    let components: [String]
    let isDirectory: Bool
    let isSymlink: Bool
    // The next five are only meaningful for zip entries.
    var method: UInt16 = 0
    var flags: UInt16 = 0
    var crc: UInt32 = 0
    var compressedSize: UInt64 = 0
    let uncompressedSize: UInt64
    var localHeaderOffset: UInt64 = 0
    var modified: Date? = nil
    var permissions: Int? = nil

    var isEncrypted: Bool { flags & 1 != 0 }
    var path: String { components.joined(separator: "/") }
}

enum ZipError: LocalizedError {
    case notAnArchive
    case damaged
    case unsupportedMethod(String)
    case encrypted(String)
    case crcMismatch(String)
    case unsafePath(String)
    case blockedByFolder(String)
    case tool(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "This file is not a zip, rar or 7z archive that ZipPick can read."
        case .damaged: return "The archive is damaged or incomplete."
        case .unsupportedMethod(let n): return "“\(n)” uses a compression method ZipPick does not support."
        case .encrypted(let n): return "“\(n)” is password protected. ZipPick cannot extract encrypted files yet."
        case .crcMismatch(let n): return "“\(n)” failed its integrity check. The archive may be damaged."
        case .unsafePath(let n): return "“\(n)” would be written outside the destination folder, so it was blocked."
        case .blockedByFolder(let n): return "A folder named “\(n)” is in the way of a file with the same name."
        case .tool(let message): return message
        case .cancelled: return "Cancelled."
        }
    }
}

/// One thing to write to disk: an archive entry and where it goes, relative to the destination.
struct PlanItem {
    let entry: ArchiveEntry
    let relativeComponents: [String]

    func target(in destination: URL) -> URL {
        relativeComponents.reduce(destination) { $0.appendingPathComponent($1) }
    }
}

struct ExtractionPlan {
    /// Every file (and empty folder) to write.
    var items: [PlanItem] = []
    /// The ticked items as the user sees them: whole folders stay one entry. Paths inside the archive.
    var roots: [[String]] = []
    /// How many leading folders are dropped from each archive path.
    var strip = 0

    var isEmpty: Bool { items.isEmpty }

    /// How many files in the plan already exist in the destination.
    func existingCount(in destination: URL) -> Int {
        let fm = FileManager.default
        return items.reduce(0) { total, item in
            guard !item.entry.isDirectory else { return total }
            return total + (fm.fileExists(atPath: item.target(in: destination).path) ? 1 : 0)
        }
    }
}

enum ConflictPolicy { case replace, skip }

struct ExtractResult {
    var written = 0
    var skipped = 0
    var topLevel: [URL] = []
}

protocol Archive: AnyObject {
    var url: URL { get }
    var entries: [ArchiveEntry] { get }

    /// `progress` receives a fraction from 0 to 1.
    func extract(
        _ plan: ExtractionPlan,
        to destination: URL,
        policy: ConflictPolicy,
        progress: (Double) -> Void,
        isCancelled: () -> Bool
    ) throws -> ExtractResult
}

enum ArchiveKind {
    case zip, rar, sevenZip

    /// Identifies the format from the file's first bytes, so a wrong extension does not matter.
    static func detect(_ url: URL) -> ArchiveKind? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = [UInt8]((try? fh.read(upToCount: 8)) ?? Data())
        if head.starts(with: [0x50, 0x4B]) { return .zip }
        if head.starts(with: [0x52, 0x61, 0x72, 0x21]) { return .rar }
        if head.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        return nil
    }
}

func openArchive(_ url: URL) throws -> Archive {
    switch ArchiveKind.detect(url) {
    case .zip: return try ZipArchive(url: url)
    case .rar, .sevenZip: return try SystemToolArchive(url: url)
    case nil:
        // Self-extracting zips start with a program, so the header check misses them.
        if let zip = try? ZipArchive(url: url) { return zip }
        throw ZipError.notAnArchive
    }
}
