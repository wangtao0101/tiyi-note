import SwiftUI

/// The public entry point used by the Tiyi app. The document implementation stays private to
/// this package so it can evolve without leaking the original standalone app's internal model.
public struct TiyiDocumentsView: View {
    @StateObject private var libraries: DocumentLibraryManager
    private let imports: TiyiPDFImportController?
    private let onExit: () -> Void
    private let librarySidebar: AnyView?
    private let libraryContainer: ((AnyView) -> AnyView)?

    public init(onExit: @escaping () -> Void, imports: TiyiPDFImportController? = nil) {
        _libraries = StateObject(wrappedValue: imports?.libraries ?? DocumentLibraryManager())
        self.imports = imports
        self.onExit = onExit
        librarySidebar = nil
        libraryContainer = nil
    }

    /// The host app's navigation is mounted only beside the library. Opening a document removes
    /// that sidebar and presents the existing editor directly, without a drawer or compositing
    /// effects around PencilKit's live surface.
    public init<Sidebar: View>(
        onExit: @escaping () -> Void,
        imports: TiyiPDFImportController? = nil,
        @ViewBuilder librarySidebar: () -> Sidebar
    ) {
        _libraries = StateObject(wrappedValue: imports?.libraries ?? DocumentLibraryManager())
        self.imports = imports
        self.onExit = onExit
        self.librarySidebar = AnyView(librarySidebar())
        libraryContainer = nil
    }

    /// A phone host can supply its drawer around the library only. The editor is rendered
    /// outside this container, keeping host navigation gestures away from its canvas.
    public init<LibraryContainer: View>(
        onExit: @escaping () -> Void,
        imports: TiyiPDFImportController? = nil,
        @ViewBuilder libraryContainer: @escaping (AnyView) -> LibraryContainer
    ) {
        _libraries = StateObject(wrappedValue: imports?.libraries ?? DocumentLibraryManager())
        self.imports = imports
        self.onExit = onExit
        librarySidebar = nil
        self.libraryContainer = { AnyView(libraryContainer($0)) }
    }

    public var body: some View {
        Group {
        RootWorkspaceView(
            documentStore: libraries.currentStore,
            onExit: onExit,
            librarySidebar: librarySidebar,
            libraryContainer: libraryContainer,
            imports: imports,
            libraryManager: libraries,
            libraryID: libraries.selectedID
        )
        .id(libraries.selectedID)
        }
        .onAppear {
            libraries.enterDocuments()
            libraries.isPresentingDocuments = true
        }
        .onDisappear { libraries.isPresentingDocuments = false }
        .task { await libraries.refresh(force: true) }
        .alert("文稿库", isPresented: Binding(get: { libraries.errorMessage != nil },
            set: { if !$0 { libraries.errorMessage = nil } })) {
            Button("好", role: .cancel) { libraries.errorMessage = nil }
        } message: { Text(libraries.errorMessage ?? "") }
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
