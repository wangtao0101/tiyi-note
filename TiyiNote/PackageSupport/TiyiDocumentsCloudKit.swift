import CloudKit
import Foundation

extension Notification.Name {
    static let tiyiCloudKitShareAccepted = Notification.Name("TiyiNote.CloudKitShareAccepted")
    static let tiyiCloudKitShareAcceptanceFailed = Notification.Name(
        "TiyiNote.CloudKitShareAcceptanceFailed"
    )
    static let tiyiCloudKitRemoteChange = Notification.Name("TiyiNote.CloudKitRemoteChange")
}

/// Bridges lifecycle callbacks owned by the host application into the document package.
public enum TiyiDocumentsCloudKit {
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
