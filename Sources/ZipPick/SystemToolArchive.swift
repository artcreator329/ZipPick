import Foundation

/// Reads rar and 7z archives through `bsdtar`, the libarchive tool that ships with macOS.
/// Nothing extra has to be installed or bundled.
final class SystemToolArchive: Archive {
    private static let tool = "/usr/bin/bsdtar"

    let url: URL
    private(set) var entries: [ArchiveEntry] = []

    init(url: URL) throws {
        self.url = url
        // Two listings: the plain one gives exact names, the verbose one gives type and size.
        let names = try Self.run(["-tf", url.path]).lines
        let details = try Self.run(["-tvf", url.path]).lines
        let hasDetails = details.count == names.count

        for (index, name) in names.enumerated() where !name.isEmpty {
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.contains("..") { continue }
            let components = parts.filter { $0 != "." }
            guard !components.isEmpty else { continue }

            var kind: Character = "-"
            var size: UInt64 = 0
            if hasDetails {
                let fields = details[index].split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
                if let first = fields.first?.first { kind = first }
                if fields.count > 4 { size = UInt64(fields[4]) ?? 0 }
            }
            let isDirectory = kind == "d" || name.hasSuffix("/")
            entries.append(ArchiveEntry(
                components: components,
                isDirectory: isDirectory,
                isSymlink: kind == "l",
                uncompressedSize: isDirectory ? 0 : size
            ))
        }
    }

    func extract(
        _ plan: ExtractionPlan,
        to destination: URL,
        policy: ConflictPolicy,
        progress: (Double) -> Void,
        isCancelled: () -> Bool
    ) throws -> ExtractResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Everything lands in a hidden staging folder first, so a failed or cancelled run
        // leaves nothing half-written and existing files are only touched on purpose.
        let staging = destination.appendingPathComponent(".zippick-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let list = fm.temporaryDirectory.appendingPathComponent("zippick-\(UUID().uuidString).txt")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: list)
        }
        let patterns = plan.roots.map { Self.escape($0.joined(separator: "/")) }
        try patterns.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)

        let expected = Double(max(plan.items.count, 1))
        var seen = 0.0
        // The tool runs to completion inside this call, so the closures never outlive it.
        try withoutActuallyEscaping(progress) { progress in
            try withoutActuallyEscaping(isCancelled) { isCancelled in
                do {
                    _ = try Self.run(
                        ["-xvf", url.path, "-C", staging.path, "--strip-components", String(plan.strip), "-T", list.path],
                        onErrorLine: { line in
                            guard line.hasPrefix("x ") else { return }
                            seen += 1
                            progress(min(seen / expected, 1) * 0.95)
                        },
                        isCancelled: isCancelled)
                } catch ZipError.tool(let message) where message.localizedCaseInsensitiveContains("encrypt")
                    || message.localizedCaseInsensitiveContains("passphrase") {
                    throw ZipError.encrypted(url.lastPathComponent)
                }
            }
        }

        let root = destination.resolvingSymlinksInPath().path
        var result = ExtractResult()
        var seenTop = Set<String>()
        for item in plan.items {
            if isCancelled() { throw ZipError.cancelled }
            let source = item.target(in: staging)
            let target = item.target(in: destination)
            if let top = item.relativeComponents.first, seenTop.insert(top).inserted {
                result.topLevel.append(destination.appendingPathComponent(top))
            }
            if item.entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // attributesOfItem does not follow symlinks, so a dangling link still counts as present.
            guard (try? fm.attributesOfItem(atPath: source.path)) != nil else {
                result.skipped += 1
                continue
            }
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let resolvedParent = parent.resolvingSymlinksInPath().path
            guard resolvedParent == root || resolvedParent.hasPrefix(root + "/") else {
                throw ZipError.unsafePath(item.entry.path)
            }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: target.path, isDirectory: &isDir)
                || (try? fm.attributesOfItem(atPath: target.path)) != nil
            if exists {
                if policy == .skip { result.skipped += 1; continue }
                if isDir.boolValue { throw ZipError.blockedByFolder(item.entry.path) }
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: source, to: target)
            result.written += 1
        }
        progress(1)
        return result
    }

    /// bsdtar treats names as wildcard patterns, so the wildcard characters are escaped.
    private static func escape(_ path: String) -> String {
        var out = ""
        for character in path {
            if "\\*?[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private struct Output {
        let lines: [String]
    }

    private static func run(
        _ arguments: [String],
        onErrorLine: ((String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // A UTF-8 locale keeps non-English file names intact instead of escaped.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var outData = Data()
        var errorLines: [String] = []
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            var pending = Data()
            let handle = stderr.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    lock.lock(); errorLines.append(line); lock.unlock()
                    onErrorLine?(line)
                }
            }
            group.leave()
        }

        try process.run()
        var cancelled = false
        while process.isRunning {
            if isCancelled?() == true {
                cancelled = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()
        if cancelled { throw ZipError.cancelled }

        guard process.terminationStatus == 0 else {
            // Progress lines look like "x path"; a failed entry looks like "x path: reason".
            let problems = errorLines.filter { !$0.isEmpty && !($0.hasPrefix("x ") && !$0.contains(": ")) }
            let detail = problems.first { !$0.contains("Error exit delayed") } ?? "The archive could not be read."
            let cleaned = detail.replacingOccurrences(of: "bsdtar: ", with: "")
            throw ZipError.tool(cleaned)
        }
        let text = String(decoding: outData, as: UTF8.self)
        return Output(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }
}
