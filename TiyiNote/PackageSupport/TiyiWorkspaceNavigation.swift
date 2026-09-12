import SwiftUI

/// Shared document-tab chrome for a host that coordinates several Note workspaces.
public struct TiyiWorkspaceTab: Identifiable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct TiyiWorkspaceNavigation {
    public let tabs: [TiyiWorkspaceTab]
    public let selectedID: String
    public let onSelect: (String) -> Void
    public let onClose: (String) -> Void
    public let onMove: (String, String) -> Void
    public let actions: AnyView
    public init(tabs: [TiyiWorkspaceTab], selectedID: String, onSelect: @escaping (String) -> Void,
                onClose: @escaping (String) -> Void, onMove: @escaping (String, String) -> Void,
                actions: AnyView = AnyView(EmptyView())) {
        self.tabs = tabs; self.selectedID = selectedID; self.onSelect = onSelect
        self.onClose = onClose; self.onMove = onMove; self.actions = actions
    }
}
