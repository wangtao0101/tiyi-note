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
            canEditAnnotations: false,
            supportsDocumentTabs: true
        )
#else
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return PlatformCapabilities(
            canManageLibrary: isPad,
            canImportPDF: isPad,
            canScanDocuments: isPad,
            canEditAnnotations: isPad,
            supportsDocumentTabs: true
        )
#endif
    }
}
