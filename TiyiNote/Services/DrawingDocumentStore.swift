import Foundation
import PDFKit
import PencilKit
import UIKit

enum LocalSaveState {
    case saved(Date?)
    case saving
    case failed(String)
}

struct PDFWorkspaceDocument: Identifiable, Hashable {
    let id: String
    let title: String
    let fileURL: URL
    let isBundled: Bool
}

struct CanvasImageAnnotation: Identifiable {
    let id: UUID
    let image: UIImage
    var logicalBounds: CGRect
    var rotationRadians: CGFloat
}

private struct StoredCanvasImageAnnotation: Codable {
    let id: UUID
    let pngData: Data
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let rotationRadians: Double

    init?(_ annotation: CanvasImageAnnotation) {
        guard let pngData = annotation.image.pngData() else { return nil }
        id = annotation.id
        self.pngData = pngData
        x = Double(annotation.logicalBounds.minX)
        y = Double(annotation.logicalBounds.minY)
        width = Double(annotation.logicalBounds.width)
        height = Double(annotation.logicalBounds.height)
        rotationRadians = Double(annotation.rotationRadians)
    }

    var annotation: CanvasImageAnnotation? {
        guard let image = UIImage(data: pngData) else { return nil }
        return CanvasImageAnnotation(
            id: id,
            image: image,
            logicalBounds: CGRect(
                x: CGFloat(x),
                y: CGFloat(y),
                width: CGFloat(width),
                height: CGFloat(height)
            ),
            rotationRadians: CGFloat(rotationRadians)
        )
    }
}

private struct ImportedPDFRecord: Codable {
    let id: String
    let title: String
    let fileName: String
}

enum PDFWorkspaceError: LocalizedError {
    case cannotAccess(String)
    case invalidPDF(String)

    var errorDescription: String? {
        switch self {
        case .cannotAccess(let name): "无法读取文件：\(name)"
        case .invalidPDF(let name): "不是有效的 PDF：\(name)"
        }
    }
}

@MainActor
final class DrawingDocumentStore: ObservableObject {
    @Published private(set) var saveState: LocalSaveState = .saved(nil)
    @Published private(set) var documents: [PDFWorkspaceDocument] = []
    @Published private(set) var openDocumentIDs: [String] = []

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let workspaceDirectory: URL
    private let importsDirectory: URL
    private let drawingsDirectory: URL
    private let registryURL: URL

    private var importedRecords: [ImportedPDFRecord] = []
    private var pdfCache: [String: PDFDocument] = [:]
    private var thumbnailCache: [String: UIImage] = [:]
    private var pendingSaves: [String: Task<Void, Never>] = [:]

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        workspaceDirectory = applicationSupport
            .appendingPathComponent("TiyiNote", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
        importsDirectory = workspaceDirectory.appendingPathComponent("PDFs", isDirectory: true)
        drawingsDirectory = workspaceDirectory.appendingPathComponent("Drawings", isDirectory: true)
        registryURL = workspaceDirectory.appendingPathComponent("documents.json")

        try? fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: drawingsDirectory, withIntermediateDirectories: true)

        migrateLegacyCongruenceDrawings(from: applicationSupport)
        loadWorkspace()
    }

    deinit {
        pendingSaves.values.forEach { $0.cancel() }
    }

    var openDocuments: [PDFWorkspaceDocument] {
        openDocumentIDs.compactMap { id in
            documents.first(where: { $0.id == id })
        }
    }

    func document(withID documentID: String) -> PDFWorkspaceDocument? {
        documents.first(where: { $0.id == documentID })
    }

    func openDocument(_ documentID: String) {
        guard document(withID: documentID) != nil else { return }
        if !openDocumentIDs.contains(documentID) {
            openDocumentIDs.append(documentID)
            persistOpenDocuments()
        }
    }

    func closeDocument(_ documentID: String) {
        guard openDocumentIDs.count > 1 else { return }
        openDocumentIDs.removeAll(where: { $0 == documentID })
        persistOpenDocuments()
    }

    @discardableResult
    func importPDFs(from urls: [URL]) throws -> [PDFWorkspaceDocument] {
        var importedDocuments: [PDFWorkspaceDocument] = []

        for sourceURL in urls {
            let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let documentID = UUID().uuidString.lowercased()
            let targetFileName = "\(documentID).pdf"
            let targetURL = importsDirectory.appendingPathComponent(targetFileName)

            do {
                try fileManager.copyItem(at: sourceURL, to: targetURL)
            } catch {
                throw PDFWorkspaceError.cannotAccess(sourceURL.lastPathComponent)
            }

            guard let pdfDocument = PDFDocument(url: targetURL), pdfDocument.pageCount > 0 else {
                try? fileManager.removeItem(at: targetURL)
                throw PDFWorkspaceError.invalidPDF(sourceURL.lastPathComponent)
            }

            let title = sourceURL.lastPathComponent
            let record = ImportedPDFRecord(id: documentID, title: title, fileName: targetFileName)
            let workspaceDocument = PDFWorkspaceDocument(
                id: documentID,
                title: title,
                fileURL: targetURL,
                isBundled: false
            )

            importedRecords.append(record)
            documents.append(workspaceDocument)
            pdfCache[documentID] = pdfDocument
            openDocumentIDs.append(documentID)
            importedDocuments.append(workspaceDocument)
        }

        try persistRegistry()
        persistOpenDocuments()
        return importedDocuments
    }

    func pdfDocument(for documentID: String) -> PDFDocument? {
        if let cachedDocument = pdfCache[documentID] {
            return cachedDocument
        }
        guard let workspaceDocument = document(withID: documentID) else { return nil }
        let pdfDocument = PDFDocument(url: workspaceDocument.fileURL)
        pdfCache[documentID] = pdfDocument
        return pdfDocument
    }

    func pageCount(for documentID: String) -> Int {
        pdfDocument(for: documentID)?.pageCount ?? 0
    }

    func page(at index: Int, in documentID: String) -> PDFPage? {
        guard index >= 0, index < pageCount(for: documentID) else { return nil }
        return pdfDocument(for: documentID)?.page(at: index)
    }

    func pageSize(at index: Int, in documentID: String) -> CGSize {
        guard let page = page(at: index, in: documentID) else {
            return CGSize(width: 595, height: 842)
        }
        let bounds = page.bounds(for: .mediaBox)
        let rotation = abs(page.rotation) % 180
        return rotation == 90
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    func thumbnail(
        forPage index: Int,
        in documentID: String,
        size: CGSize
    ) -> UIImage? {
        let cacheKey = "\(documentID)#\(index)#\(Int(size.width))x\(Int(size.height))"
        if let cachedImage = thumbnailCache[cacheKey] {
            return cachedImage
        }
        guard let page = page(at: index, in: documentID) else { return nil }
        let image = page.thumbnail(of: size, for: .mediaBox)
        thumbnailCache[cacheKey] = image
        return image
    }

    func loadDrawing(forPage pageIndex: Int, in documentID: String) -> PKDrawing {
        let drawingURL = drawingURL(forPage: pageIndex, in: documentID)
        guard
            let data = try? Data(contentsOf: drawingURL),
            let drawing = try? PKDrawing(data: data)
        else {
            return PKDrawing()
        }
        return drawing
    }

    func loadImageAnnotations(
        forPage pageIndex: Int,
        in documentID: String
    ) -> [CanvasImageAnnotation] {
        guard
            let data = try? Data(contentsOf: imageAnnotationsURL(forPage: pageIndex, in: documentID)),
            let storedAnnotations = try? JSONDecoder().decode(
                [StoredCanvasImageAnnotation].self,
                from: data
            )
        else { return [] }
        return storedAnnotations.compactMap(\.annotation)
    }

    func scheduleSave(
        _ drawing: PKDrawing,
        forPage pageIndex: Int,
        in documentID: String
    ) {
        let saveKey = drawingKey(documentID: documentID, pageIndex: pageIndex)
        pendingSaves[saveKey]?.cancel()
        saveState = .saving

        let data = drawing.dataRepresentation()
        let targetURL = drawingURL(forPage: pageIndex, in: documentID)
        pendingSaves[saveKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }

            do {
                try await Task.detached(priority: .utility) {
                    try data.write(to: targetURL, options: .atomic)
                }.value
                guard !Task.isCancelled else { return }
                self?.pendingSaves[saveKey] = nil
                self?.saveState = self?.pendingSaves.isEmpty == true ? .saved(Date()) : .saving
            } catch {
                self?.pendingSaves[saveKey] = nil
                self?.saveState = .failed(error.localizedDescription)
            }
        }
    }

    func scheduleSave(
        _ imageAnnotations: [CanvasImageAnnotation],
        forPage pageIndex: Int,
        in documentID: String
    ) {
        let saveKey = "\(drawingKey(documentID: documentID, pageIndex: pageIndex))#images"
        pendingSaves[saveKey]?.cancel()
        guard
            let data = try? JSONEncoder().encode(
                imageAnnotations.compactMap(StoredCanvasImageAnnotation.init)
            )
        else {
            saveState = .failed("图片批注无法保存")
            return
        }
        saveState = .saving
        let targetURL = imageAnnotationsURL(forPage: pageIndex, in: documentID)
        pendingSaves[saveKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try data.write(to: targetURL, options: .atomic)
                }.value
                guard !Task.isCancelled else { return }
                self?.pendingSaves[saveKey] = nil
                self?.saveState = self?.pendingSaves.isEmpty == true ? .saved(Date()) : .saving
            } catch {
                self?.pendingSaves[saveKey] = nil
                self?.saveState = .failed(error.localizedDescription)
            }
        }
    }

    func flush(
        _ drawing: PKDrawing,
        forPage pageIndex: Int,
        in documentID: String
    ) {
        let saveKey = drawingKey(documentID: documentID, pageIndex: pageIndex)
        pendingSaves[saveKey]?.cancel()
        pendingSaves[saveKey] = nil

        do {
            try drawing.dataRepresentation().write(
                to: drawingURL(forPage: pageIndex, in: documentID),
                options: .atomic
            )
            saveState = pendingSaves.isEmpty ? .saved(Date()) : .saving
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func flush(
        _ imageAnnotations: [CanvasImageAnnotation],
        forPage pageIndex: Int,
        in documentID: String
    ) {
        let saveKey = "\(drawingKey(documentID: documentID, pageIndex: pageIndex))#images"
        pendingSaves[saveKey]?.cancel()
        pendingSaves[saveKey] = nil
        guard
            let data = try? JSONEncoder().encode(
                imageAnnotations.compactMap(StoredCanvasImageAnnotation.init)
            )
        else {
            saveState = .failed("图片批注无法保存")
            return
        }
        do {
            try data.write(
                to: imageAnnotationsURL(forPage: pageIndex, in: documentID),
                options: .atomic
            )
            saveState = pendingSaves.isEmpty ? .saved(Date()) : .saving
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func lastViewedPage(for documentID: String) -> Int {
        let storedPage = userDefaults.integer(forKey: lastPageKey(documentID))
        return min(max(storedPage, 0), max(pageCount(for: documentID) - 1, 0))
    }

    func setLastViewedPage(_ pageIndex: Int, for documentID: String) {
        userDefaults.set(pageIndex, forKey: lastPageKey(documentID))
    }

    private func loadWorkspace() {
        var loadedDocuments: [PDFWorkspaceDocument] = []

        if let congruenceURL = Bundle.main.url(forResource: "Congruence", withExtension: "pdf") {
            loadedDocuments.append(
                PDFWorkspaceDocument(
                    id: "congruence",
                    title: "初中数学竞赛中的数论初步-同余.pdf",
                    fileURL: congruenceURL,
                    isBundled: true
                )
            )
        }

        if let geometryURL = Bundle.main.url(forResource: "Geometry", withExtension: "pdf") {
            loadedDocuments.append(
                PDFWorkspaceDocument(
                    id: "geometry",
                    title: "2026马哥各地中考几何压轴-学生卷.pdf",
                    fileURL: geometryURL,
                    isBundled: true
                )
            )
        }

        if
            let registryData = try? Data(contentsOf: registryURL),
            let records = try? JSONDecoder().decode([ImportedPDFRecord].self, from: registryData)
        {
            importedRecords = records.filter { record in
                fileManager.fileExists(atPath: importsDirectory.appendingPathComponent(record.fileName).path)
            }
            loadedDocuments.append(contentsOf: importedRecords.map { record in
                PDFWorkspaceDocument(
                    id: record.id,
                    title: record.title,
                    fileURL: importsDirectory.appendingPathComponent(record.fileName),
                    isBundled: false
                )
            })
        }

        documents = loadedDocuments

        let savedOpenIDs = userDefaults.stringArray(forKey: "pdfWorkspace.openDocumentIDs") ?? []
        let availableIDs = Set(loadedDocuments.map(\.id))
        openDocumentIDs = savedOpenIDs.filter { availableIDs.contains($0) }
        if openDocumentIDs.isEmpty {
            openDocumentIDs = loadedDocuments.map(\.id)
        } else {
            for bundledDocument in loadedDocuments where bundledDocument.isBundled {
                if !openDocumentIDs.contains(bundledDocument.id) {
                    openDocumentIDs.append(bundledDocument.id)
                }
            }
        }
        persistOpenDocuments()
    }

    private func persistRegistry() throws {
        let data = try JSONEncoder().encode(importedRecords)
        try data.write(to: registryURL, options: .atomic)
    }

    private func migrateLegacyCongruenceDrawings(from applicationSupport: URL) {
        let legacyDirectory = applicationSupport
            .appendingPathComponent("TiyiNote", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Congruence", isDirectory: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        let targetDirectory = drawingsDirectory.appendingPathComponent("Congruence", isDirectory: true)

        guard
            let legacyFiles = try? fileManager.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: nil
            ),
            !legacyFiles.isEmpty
        else { return }

        try? fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        for sourceURL in legacyFiles where sourceURL.pathExtension == "drawing" {
            let targetURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if !fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.copyItem(at: sourceURL, to: targetURL)
            }
        }
    }

    private func persistOpenDocuments() {
        userDefaults.set(openDocumentIDs, forKey: "pdfWorkspace.openDocumentIDs")
    }

    private func drawingURL(forPage pageIndex: Int, in documentID: String) -> URL {
        let documentDirectoryName: String
        switch documentID {
        case "congruence": documentDirectoryName = "Congruence"
        case "geometry": documentDirectoryName = "Geometry"
        default: documentDirectoryName = documentID
        }

        let documentDrawingsDirectory = drawingsDirectory
            .appendingPathComponent(documentDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(
            at: documentDrawingsDirectory,
            withIntermediateDirectories: true
        )
        return documentDrawingsDirectory.appendingPathComponent(
            String(format: "page-%04d.drawing", pageIndex + 1)
        )
    }

    private func imageAnnotationsURL(forPage pageIndex: Int, in documentID: String) -> URL {
        drawingURL(forPage: pageIndex, in: documentID)
            .deletingPathExtension()
            .appendingPathExtension("images.json")
    }

    private func drawingKey(documentID: String, pageIndex: Int) -> String {
        "\(documentID)#\(pageIndex)"
    }

    private func lastPageKey(_ documentID: String) -> String {
        "pdfWorkspace.lastPage.\(documentID)"
    }
}
