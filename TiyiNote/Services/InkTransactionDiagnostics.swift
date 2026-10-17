import Foundation

/// Bounded, device-local transaction metadata. Never records stroke points, text or document
/// titles. All encoding and file I/O run off the UI actor; drawing callbacks only enqueue scalars.
enum InkTransactionDiagnostics {
    private struct Event: Encodable, Sendable {
        let revision = 3
        let time: TimeInterval
        let session: String
        let canvas: String
        let page: String?
        let action: String
        let known: Int
        let native: Int?
        let cutoff: TimeInterval?
        let samples: Int?
        let erasePasses: Int?
        let erasePathFraction: Double?
        let removedInk: Int?
        let removedObjects: Int?
        let tool: String?
        let undoDepth: Int?
        let redoDepth: Int?
        let queuedHistory: Int?
    }
    private static let session = UUID().uuidString
    private static let queue = DispatchQueue(label: "com.tiyi.note.ink-diagnostics", qos: .utility)
    private static var pending: [Event] = []
    private static var flushScheduled = false
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TiyiInkDiagnostics-v1", isDirectory: true)

    static func record(canvas: String, page: String?, action: String, known: Int,
                       native: Int? = nil, cutoff: Date? = nil, samples: Int? = nil,
                       erasePasses: Int? = nil, erasePathFraction: Double? = nil,
                       removedInk: Int? = nil, removedObjects: Int? = nil,
                       tool: String? = nil, undoDepth: Int? = nil, redoDepth: Int? = nil,
                       queuedHistory: Int? = nil) {
        let event = Event(time: Date.timeIntervalSinceReferenceDate, session: session,
            canvas: canvas, page: page, action: action, known: known, native: native,
            cutoff: cutoff?.timeIntervalSinceReferenceDate, samples: samples,
            erasePasses: erasePasses, erasePathFraction: erasePathFraction,
            removedInk: removedInk, removedObjects: removedObjects,
            tool: tool, undoDepth: undoDepth, redoDepth: redoDepth, queuedHistory: queuedHistory)
        queue.async {
            pending.append(event)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 1) { flush() }
        }
    }

    private static func flush() {
        let events = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            if let line = try? encoder.encode(event) { data.append(line); data.append(0x0a) }
        }
        guard !data.isEmpty else { return }
        let file = directory.appendingPathComponent("events.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes + data.count > 256 * 1_024 {
                let previous = directory.appendingPathComponent("previous.jsonl")
                try? FileManager.default.removeItem(at: previous)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: previous) }
            }
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { /* Diagnostics must never affect ink editing or persistence. */ }
    }
}
