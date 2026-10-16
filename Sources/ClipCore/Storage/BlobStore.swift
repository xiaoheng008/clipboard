import Foundation

/// Content-addressed, immutable files. Write protocol: tmp → fsync → rename, *before* the DB commit,
/// so "item exists ⇒ blob exists" (I2) always holds. Orphans are harmless and collected by `--gc`.
public struct BlobStore: Sendable {
    public let home: AppHome
    public init(home: AppHome) { self.home = home }

    public func url(for hash: String) -> URL {
        home.blobsURL.appendingPathComponent(String(hash.prefix(2)), isDirectory: true).appendingPathComponent(hash)
    }

    public func exists(_ hash: String) -> Bool { FileManager.default.fileExists(atPath: url(for: hash).path) }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hash = ContentHasher.sha256Hex(data)
        let dest = url(for: hash)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            // Refresh mtime: a re-put blob is "in use" again and inside gc's grace period (R4).
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return hash
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = home.tmpURL.appendingPathComponent("blob-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let fh = try FileHandle(forWritingTo: tmp)
            try fh.write(contentsOf: data)
            try fh.synchronize()
            try fh.close()
            if rename(tmp.path, dest.path) != 0 {
                // Another writer may have won the race; identical content either way.
                if !fm.fileExists(atPath: dest.path) { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try? fm.removeItem(at: tmp)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return hash
    }

    public func delete(_ hash: String) throws {
        let fm = FileManager.default
        let u = url(for: hash)
        if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        let thumb = thumbnailURL(for: hash)
        if fm.fileExists(atPath: thumb.path) { try? fm.removeItem(at: thumb) }
    }

    public func thumbnailURL(for hash: String) -> URL {
        home.thumbsURL.appendingPathComponent(String(hash.prefix(2)), isDirectory: true).appendingPathComponent(hash + ".jpg")
    }

    public func allHashes() throws -> Set<String> {
        var out = Set<String>()
        let fm = FileManager.default
        for shard in try fm.contentsOfDirectory(atPath: home.blobsURL.path) where shard.count == 2 {
            for name in try fm.contentsOfDirectory(atPath: home.blobsURL.appendingPathComponent(shard).path) {
                out.insert(name)
            }
        }
        return out
    }

    public func modificationDate(_ hash: String) -> Date? {
        try? url(for: hash).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func totalBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: home.blobsURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
