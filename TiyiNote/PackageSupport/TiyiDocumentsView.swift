import SwiftUI

/// The public entry point used by the Tiyi app. The document implementation stays private to
/// this package so it can evolve without leaking the original standalone app's internal model.
public struct TiyiDocumentsView: View {
    @StateObject private var documentStore: DrawingDocumentStore
    private let onExit: () -> Void

    public init(onExit: @escaping () -> Void) {
        _documentStore = StateObject(wrappedValue: DrawingDocumentStore())
        self.onExit = onExit
    }

    public var body: some View {
        RootWorkspaceView(
            documentStore: documentStore,
            onExit: onExit
        )
#if targetEnvironment(macCatalyst)
        .background {
            CatalystImmersiveWindowChrome()
                .allowsHitTesting(false)
        }
#endif
    }
}

#if targetEnvironment(macCatalyst)
private struct CatalystImmersiveWindowChrome: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.applyWindowChrome()
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: ()) {
        uiViewController.restoreWindowChrome()
    }

    @MainActor
    final class Controller: UIViewController {
        private weak var configuredTitlebar: UITitlebar?
        private var originalTitleVisibility: UITitlebarTitleVisibility?
        private var originalToolbarStyle: UITitlebarToolbarStyle?
        private var originalSeparatorStyle: UITitlebarSeparatorStyle?
        private var restoreToolbar: (() -> Void)?

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyWindowChrome()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.applyWindowChrome()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyWindowChrome()
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            applyWindowChrome()
        }

        func applyWindowChrome() {
            guard let titlebar = view.window?.windowScene?.titlebar else { return }
            if configuredTitlebar !== titlebar {
                restoreWindowChrome()
                configuredTitlebar = titlebar
                originalTitleVisibility = titlebar.titleVisibility
                originalToolbarStyle = titlebar.toolbarStyle
                originalSeparatorStyle = titlebar.separatorStyle
                let originalToolbar = titlebar.toolbar
                restoreToolbar = { [weak titlebar] in
                    titlebar?.toolbar = originalToolbar
                }
            }

            if titlebar.titleVisibility != .hidden {
                titlebar.titleVisibility = .hidden
            }
            if titlebar.toolbarStyle != .unifiedCompact {
                titlebar.toolbarStyle = .unifiedCompact
            }
            if titlebar.separatorStyle != .none {
                titlebar.separatorStyle = .none
            }
            if titlebar.toolbar != nil {
                titlebar.toolbar = nil
            }
        }

        func restoreWindowChrome() {
            guard let titlebar = configuredTitlebar else { return }
            if let originalTitleVisibility {
                titlebar.titleVisibility = originalTitleVisibility
            }
            if let originalToolbarStyle {
                titlebar.toolbarStyle = originalToolbarStyle
            }
            if let originalSeparatorStyle {
                titlebar.separatorStyle = originalSeparatorStyle
            }
            restoreToolbar?()
            configuredTitlebar = nil
            restoreToolbar = nil
        }
    }
}
#endif
