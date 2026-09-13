import CloudKit
import Foundation
import UIKit

extension Notification.Name {
    static let tiyiCloudKitShareAccepted = Notification.Name("TiyiNote.CloudKitShareAccepted")
    static let tiyiCloudKitShareAcceptanceFailed = Notification.Name(
        "TiyiNote.CloudKitShareAcceptanceFailed"
    )
    static let tiyiCloudKitRemoteChange = Notification.Name("TiyiNote.CloudKitRemoteChange")
}

/// Bridges lifecycle callbacks owned by the host application into the document package.
public enum TiyiDocumentsCloudKit {
    public static func isShareURL(_ url: URL) -> Bool {
        FamilyLibraryInvitation.isShareURL(url)
    }

    /// Fetch and accept using the device's iCloud account, without a browser session.
    public static func acceptShare(at url: URL) async throws {
        try await FamilyLibraryInvitation.accept(url, familyOnly: false)
    }

    public static func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            try await CloudDocumentShareService.accept(metadata)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .tiyiCloudKitShareAccepted,
                    object: metadata
                )
            }
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .tiyiCloudKitShareAcceptanceFailed,
                    object: error
                )
            }
        }
    }

    @discardableResult
    public static func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any]
    ) -> Bool {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            return false
        }
        NotificationCenter.default.post(name: .tiyiCloudKitRemoteChange, object: nil)
        return true
    }
}

/// SwiftUI uses scenes: UIKit delivers warm invitations to UIWindowSceneDelegate and cold
/// invitations through connection options. The application callback remains a legacy fallback.
public final class TiyiDocumentsSceneDelegate: NSObject, UIWindowSceneDelegate {
    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { await TiyiDocumentsCloudKit.acceptShare(metadata) }
        }
    }

    public func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await TiyiDocumentsCloudKit.acceptShare(metadata) }
    }
}
