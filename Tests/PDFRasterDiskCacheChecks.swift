import Foundation

@main
struct PDFRasterDiskCacheChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cache-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let small = Data(repeating: 1, count: 40)
        let cache = PDFRasterDiskCache(directory: root, maximumPages: 2, maximumBytes: 120)
        cache.store(small, for: "first", variant: .page)
        cache.store(small, for: "first", variant: .thumbnail)
        cache.store(small, for: "second", variant: .page)
        let reopened = PDFRasterDiskCache(directory: root, maximumPages: 2, maximumBytes: 120)
        precondition(reopened.data(for: "first", variant: .page) == small, "Images must survive a new cache instance")
        precondition(reopened.data(for: "first", variant: .thumbnail) == small, "Two variants count as one page")
        reopened.store(small, for: "third", variant: .page)
        precondition(reopened.data(for: "second", variant: .page) == nil, "Evict the least recently read page")
        precondition(reopened.data(for: "first", variant: .page) == small)
        precondition(reopened.data(for: "third", variant: .page) == small)
        reopened.store(Data(repeating: 2, count: 90), for: "fourth", variant: .page)
        precondition(reopened.data(for: "first", variant: .thumbnail) == nil, "Byte limit applies across both variants")
        precondition(reopened.data(for: "third", variant: .page) == nil)
        precondition(reopened.data(for: "fourth", variant: .page)?.count == 90)
        precondition(reopened.data(for: "fourth-rotated", variant: .page) == nil, "Changed page versions must miss")
        reopened.store(Data(count: 121), for: "oversized", variant: .page)
        precondition(reopened.data(for: "oversized", variant: .page) == nil)
        let disabled = PDFRasterDiskCache(directory: root.appendingPathComponent("disabled"), maximumPages: 0)
        disabled.store(small, for: "page", variant: .page)
        precondition(disabled.data(for: "page", variant: .page) == nil)
        print("PASS: persistence, two variants per page, LRU reads, page/byte limits, version misses, oversized entries")
    }
}
