import CryptoKit
import Foundation

/// Regenerable, device-local images. One entry is a page version, with a full raster and/or
/// thumbnail. Neither this directory nor its LRU metadata belongs in document sync or backups.
final class PDFRasterDiskCache: @unchecked Sendable {
    static let shared = PDFRasterDiskCache(directory: FileManager.default.urls(for: .cachesDirectory,
        in: .userDomainMask)[0].appendingPathComponent("TiyiPDFRasters-v1", isDirectory: true))

    enum Variant: String { case page, thumbnail }
    let directory: URL
    private let maximumPages: Int
    private let maximumBytes: Int
    private let lock = NSLock()

    init(directory: URL, maximumPages: Int = 1_000, maximumBytes: Int = 2_000_000_000) {
        self.directory = directory
        self.maximumPages = max(0, maximumPages)
        self.maximumBytes = max(0, maximumBytes)
    }

    private func pageDirectory(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true)
    }

    func data(for key: String, variant: Variant) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let folder = pageDirectory(key)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(variant.rawValue + ".jpg")) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return data
    }

    func touch(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: pageDirectory(key).path)
    }

    func store(_ data: Data, for key: String, variant: Variant) {
        lock.lock(); defer { lock.unlock() }
        guard maximumPages > 0, data.count <= maximumBytes else { return }
        let folder = pageDirectory(key)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(variant.rawValue + ".jpg"), options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
            trim()
        } catch { /* A full/unavailable cache must never prevent the PDF from displaying. */ }
    }

    private func trim() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let entries = folders.compactMap { folder -> (url: URL, date: Date, bytes: Int)? in
            guard let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else { return nil }
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return (folder, values.contentModificationDate ?? .distantPast, bytes)
        }.sorted { $0.date < $1.date }
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries {
            guard count > maximumPages || bytes > maximumBytes else { break }
            do {
                try manager.removeItem(at: entry.url)
                count -= 1; bytes -= entry.bytes
            } catch { continue }
        }
    }
}
