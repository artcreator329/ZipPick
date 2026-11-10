import Compression
import Foundation
import zlib

private extension Data {
    func u16(_ o: Int) -> UInt16 {
        let i = startIndex + o
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 {
        UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }
    func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }
}

final class ZipArchive: Archive {
    let url: URL
    private(set) var entries: [ArchiveEntry] = []

    init(url: URL) throws {
        self.url = url
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        let size = try fh.seekToEnd()
        guard size >= 22 else { throw ZipError.notAnArchive }
        let tailLength = min(size, 65_557 + 20)
        try fh.seek(toOffset: size - tailLength)
        let tail = try fh.read(upToCount: Int(tailLength)) ?? Data()

        var eocd = -1
        var p = tail.count - 22
        while p >= 0 {
            if tail.u32(p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAnArchive }

        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))
        let count16 = tail.u16(eocd + 10)
        if count16 == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF,
           eocd >= 20, tail.u32(eocd - 20) == 0x0706_4b50 {
            let recordOffset = tail.u64(eocd - 20 + 8)
            guard recordOffset < size else { throw ZipError.damaged }
            try fh.seek(toOffset: recordOffset)
            let record = try fh.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.u32(0) == 0x0606_4b50 else { throw ZipError.damaged }
            cdSize = record.u64(40)
            cdOffset = record.u64(48)
        }
        guard cdOffset <= size, cdSize <= size - cdOffset, cdSize < UInt64(Int32.max) else {
            throw ZipError.damaged
        }
        try fh.seek(toOffset: cdOffset)
        let cd = try fh.read(upToCount: Int(cdSize)) ?? Data()
        guard cd.count == Int(cdSize) else { throw ZipError.damaged }
        entries = Self.parseCentralDirectory(cd)
    }

    private static func parseCentralDirectory(_ cd: Data) -> [ArchiveEntry] {
        var result: [ArchiveEntry] = []
        var p = 0
        while p + 46 <= cd.count, cd.u32(p) == 0x0201_4b50 {
            let madeBy = cd.u16(p + 4)
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let time = cd.u16(p + 12)
            let date = cd.u16(p + 14)
            let crc = cd.u32(p + 16)
            var compressed = UInt64(cd.u32(p + 20))
            var uncompressed = UInt64(cd.u32(p + 24))
            let nameLength = Int(cd.u16(p + 28))
            let extraLength = Int(cd.u16(p + 30))
            let commentLength = Int(cd.u16(p + 32))
            let externalAttributes = cd.u32(p + 38)
            var localOffset = UInt64(cd.u32(p + 42))
            let next = p + 46 + nameLength + extraLength + commentLength
            guard next <= cd.count else { break }

            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLength))

            // ZIP64 extra field: holds whichever of the sizes/offset overflowed 32 bits, in this order.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = cd.u16(e)
                let len = Int(cd.u16(e + 2))
                var q = e + 4
                if id == 0x0001 {
                    let end = min(q + len, extraEnd)
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= end { uncompressed = cd.u64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= end { compressed = cd.u64(q); q += 8 }
                    if localOffset == 0xFFFF_FFFF, q + 8 <= end { localOffset = cd.u64(q); q += 8 }
                }
                e += 4 + len
            }
            p = next

            var name = decodeName(nameData, utf8: flags & 0x0800 != 0)
            if !name.contains("/"), name.contains("\\") {
                name = name.replacingOccurrences(of: "\\", with: "/")
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // Entries that try to climb out of the destination are dropped outright.
            if parts.contains("..") { continue }
            let components = parts.filter { $0 != "." }
            guard !components.isEmpty else { continue }

            let unixMode: UInt32? = (madeBy >> 8) == 3 ? externalAttributes >> 16 : nil
            let fileType = (unixMode ?? 0) & 0o170000
            let isDirectory = name.hasSuffix("/") || fileType == 0o040000
            let permissions = unixMode.map { Int($0 & 0o777) }

            result.append(ArchiveEntry(
                components: components,
                isDirectory: isDirectory,
                isSymlink: fileType == 0o120000,
                method: method,
                flags: flags,
                crc: crc,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                modified: dosDate(date: date, time: time),
                permissions: (permissions ?? 0) == 0 ? nil : permissions
            ))
        }
        return result
    }

    private static func decodeName(_ data: Data, utf8: Bool) -> String {
        if utf8 { return String(decoding: data, as: UTF8.self) }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Zips made on Windows often carry names in the local code page without saying so.
        for cf in [CFStringEncodings.GB_18030_2000, CFStringEncodings.dosLatinUS] {
            let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: ns)) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dosDate(date: UInt16, time: UInt16) -> Date? {
        var c = DateComponents()
        c.year = Int(date >> 9) + 1980
        c.month = Int((date >> 5) & 0x0F)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        guard c.month! >= 1, c.day! >= 1 else { return nil }
        return Calendar.current.date(from: c)
    }

    // MARK: Extraction

    func extract(
        _ plan: ExtractionPlan,
        to destination: URL,
        policy: ConflictPolicy,
        progress report: (Double) -> Void,
        isCancelled: () -> Bool
    ) throws -> ExtractResult {
        let total = max(plan.items.reduce(UInt64(0)) { $0 + $1.entry.uncompressedSize }, 1)
        func progress(_ done: UInt64) { report(Double(done) / Double(total)) }
        let fm = FileManager.default
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.resolvingSymlinksInPath().path
        var result = ExtractResult()
        var seenTop = Set<String>()
        var done: UInt64 = 0

        for item in plan.items {
            if isCancelled() { throw ZipError.cancelled }
            let entry = item.entry
            let target = item.target(in: destination)
            if let top = item.relativeComponents.first, seenTop.insert(top).inserted {
                result.topLevel.append(destination.appendingPathComponent(top))
            }

            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if entry.isEncrypted { throw ZipError.encrypted(entry.path) }

            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // A symlink planted earlier in the archive must not redirect later writes elsewhere.
            let resolvedParent = parent.resolvingSymlinksInPath().path
            guard resolvedParent == root || resolvedParent.hasPrefix(root + "/") else {
                throw ZipError.unsafePath(entry.path)
            }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: target.path, isDirectory: &isDir)
                || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            if exists {
                if policy == .skip {
                    result.skipped += 1
                    done += entry.uncompressedSize
                    progress(done)
                    continue
                }
                if isDir.boolValue { throw ZipError.blockedByFolder(entry.path) }
            }

            if entry.isSymlink {
                var linkData = Data()
                try stream(entry, from: fh, isCancelled: isCancelled) { linkData.append(contentsOf: $0) }
                let link = String(decoding: linkData, as: UTF8.self)
                let safe = !link.hasPrefix("/") && !link.split(separator: "/").contains("..")
                guard safe else { result.skipped += 1; continue }
                if exists { try fm.removeItem(at: target) }
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                result.written += 1
                continue
            }

            let temp = parent.appendingPathComponent(".zippick-\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: temp.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: parent.path])
            }
            do {
                let out = try FileHandle(forWritingTo: temp)
                defer { try? out.close() }
                let base = done
                var written: UInt64 = 0
                try stream(entry, from: fh, isCancelled: isCancelled) { chunk in
                    try out.write(contentsOf: Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: chunk.baseAddress!),
                        count: chunk.count, deallocator: .none))
                    written += UInt64(chunk.count)
                    progress(base + written)
                }
                try out.close()
                if exists { try fm.removeItem(at: target) }
                try fm.moveItem(at: temp, to: target)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
            done += entry.uncompressedSize
            progress(done)

            var attributes: [FileAttributeKey: Any] = [:]
            if let modified = entry.modified { attributes[.modificationDate] = modified }
            if let permissions = entry.permissions { attributes[.posixPermissions] = permissions | 0o600 }
            if !attributes.isEmpty { try? fm.setAttributes(attributes, ofItemAtPath: target.path) }
            result.written += 1
        }
        return result
    }

    /// Decompresses one entry, handing the output to `sink` in chunks and checking the CRC at the end.
    private func stream(
        _ entry: ArchiveEntry,
        from fh: FileHandle,
        isCancelled: () -> Bool,
        sink: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        try fh.seek(toOffset: entry.localHeaderOffset)
        let header = try fh.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.u32(0) == 0x0403_4b50 else { throw ZipError.damaged }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        try fh.seek(toOffset: dataStart)

        let chunkSize = 1 << 18
        var remaining = entry.compressedSize
        var crc: uLong = crc32(0, nil, 0)
        var produced: UInt64 = 0

        func emit(_ buffer: UnsafeRawBufferPointer) throws {
            guard buffer.count > 0 else { return }
            crc = crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            produced += UInt64(buffer.count)
            try sink(buffer)
        }

        switch entry.method {
        case 0:
            while remaining > 0 {
                if isCancelled() { throw ZipError.cancelled }
                let chunk = try fh.read(upToCount: Int(min(remaining, UInt64(chunkSize)))) ?? Data()
                guard !chunk.isEmpty else { throw ZipError.damaged }
                remaining -= UInt64(chunk.count)
                try chunk.withUnsafeBytes { try emit($0) }
            }
        case 8:
            let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { streamPointer.deallocate() }
            guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { throw ZipError.damaged }
            defer { compression_stream_destroy(streamPointer) }

            let input = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { input.deallocate(); output.deallocate() }

            streamPointer.pointee.src_ptr = UnsafePointer(input)
            streamPointer.pointee.src_size = 0
            streamPointer.pointee.dst_ptr = output
            streamPointer.pointee.dst_size = chunkSize

            while true {
                if isCancelled() { throw ZipError.cancelled }
                if streamPointer.pointee.src_size == 0, remaining > 0 {
                    let chunk = try fh.read(upToCount: Int(min(remaining, UInt64(chunkSize)))) ?? Data()
                    guard !chunk.isEmpty else { throw ZipError.damaged }
                    remaining -= UInt64(chunk.count)
                    chunk.copyBytes(to: input, count: chunk.count)
                    streamPointer.pointee.src_ptr = UnsafePointer(input)
                    streamPointer.pointee.src_size = chunk.count
                }
                let finishing = remaining == 0
                let status = compression_stream_process(
                    streamPointer, finishing ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                let count = chunkSize - streamPointer.pointee.dst_size
                if count > 0 {
                    try emit(UnsafeRawBufferPointer(start: output, count: count))
                    streamPointer.pointee.dst_ptr = output
                    streamPointer.pointee.dst_size = chunkSize
                }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw ZipError.damaged }
                if count == 0, finishing, streamPointer.pointee.src_size == 0 { throw ZipError.damaged }
            }
        default:
            throw ZipError.unsupportedMethod(entry.path)
        }

        guard produced == entry.uncompressedSize, UInt32(truncatingIfNeeded: crc) == entry.crc else {
            throw ZipError.crcMismatch(entry.path)
        }
    }
}
