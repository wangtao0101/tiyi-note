import UIKit

/// Product capabilities are intentionally expressed in one place so shared
/// views do not accumulate scattered platform checks.
struct PlatformCapabilities {
    let canManageLibrary: Bool
    let canImportPDF: Bool
    let canScanDocuments: Bool
    let canEditAnnotations: Bool
    let supportsDocumentTabs: Bool

    static var current: PlatformCapabilities {
#if targetEnvironment(macCatalyst)
        PlatformCapabilities(
            canManageLibrary: true,
            canImportPDF: true,
            canScanDocuments: false,
            canEditAnnotations: true,
            supportsDocumentTabs: true
        )
#else
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return PlatformCapabilities(
            canManageLibrary: isPad,
            canImportPDF: isPad,
            canScanDocuments: isPad,
            canEditAnnotations: true,
            supportsDocumentTabs: true
        )
#endif
    }
}

/// Session-only interaction state. Never stored in document metadata or iCloud.
struct CanvasInteractionSession {
    enum Mode { case readOnly, writing }
    let defaultMode: Mode
    private(set) var contentID: String?
    private(set) var mode: Mode

    init(defaultMode: Mode = Self.deviceDefaultMode) {
        self.defaultMode = defaultMode
        self.mode = defaultMode
    }

    static var deviceDefaultMode: Mode {
#if targetEnvironment(macCatalyst)
        .readOnly
#else
        UIDevice.current.userInterfaceIdiom == .pad ? .writing : .readOnly
#endif
    }

    func canWrite(contentID: String, hasPermission: Bool) -> Bool {
        hasPermission && (self.contentID == contentID ? mode : defaultMode) == .writing
    }

    mutating func enter(_ contentID: String) {
        guard self.contentID != contentID else { return }
        self.contentID = contentID
        mode = defaultMode
    }

    mutating func toggle(contentID: String, hasPermission: Bool) {
        enter(contentID)
        guard hasPermission else { return }
        mode = mode == .readOnly ? .writing : .readOnly
    }
}
