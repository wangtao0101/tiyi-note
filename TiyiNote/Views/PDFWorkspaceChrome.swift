import SwiftUI

struct PDFDocumentTabBar: View {
    let openDocuments: [PDFWorkspaceDocument]
    let libraryDocuments: [PDFWorkspaceDocument]
    let activeDocumentID: String
    let saveState: LocalSaveState
    let onSelectDocument: (String) -> Void
    let onCloseDocument: (String) -> Void
    let onOpenDocument: (String) -> Void
    let onImportPDF: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Section("文档") {
                    ForEach(libraryDocuments) { document in
                        Button {
                            onOpenDocument(document.id)
                        } label: {
                            Label(
                                document.title,
                                systemImage: openDocuments.contains(where: { $0.id == document.id })
                                    ? "checkmark.circle.fill"
                                    : "doc"
                            )
                        }
                    }
                }

                Divider()

                Button(action: onImportPDF) {
                    Label("导入 PDF", systemImage: "plus")
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(TiyiNoteTheme.selectionBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(TiyiNoteTheme.selectionBorder, lineWidth: 1)
                        }
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.selectionForeground)
                }
                .frame(width: 34, height: 34)
                .frame(width: 52, height: 46)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("文档列表")

            Rectangle()
                .fill(TiyiNoteTheme.hairline)
                .frame(width: 1, height: 26)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(openDocuments) { document in
                            PDFDocumentTab(
                                document: document,
                                isActive: document.id == activeDocumentID,
                                canClose: openDocuments.count > 1,
                                onSelect: { onSelectDocument(document.id) },
                                onClose: { onCloseDocument(document.id) }
                            )
                            .id(document.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: activeDocumentID) { _, documentID in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(documentID, anchor: .center)
                    }
                }
            }

            Button(action: onImportPDF) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(TiyiNoteTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入 PDF")
            .padding(.trailing, 8)

            WorkspaceSaveStateView(state: saveState)
                .padding(.trailing, 12)
        }
        .frame(height: 48)
        .background(TiyiNoteTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TiyiNoteTheme.hairline)
                .frame(height: 1)
        }
    }
}

private struct PDFDocumentTab: View {
    let document: PDFWorkspaceDocument
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? TiyiNoteTheme.selectionForeground : TiyiNoteTheme.textTertiary)
                    Text(document.title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(isActive ? TiyiNoteTheme.selectionForeground : TiyiNoteTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isActive ? TiyiNoteTheme.selectionForeground.opacity(0.78) : TiyiNoteTheme.textTertiary)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭 \(document.title)")
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .frame(width: isActive ? 300 : 260, height: 42)
        .background(
            isActive ? TiyiNoteTheme.selectionBackground : TiyiNoteTheme.surface.opacity(0.62),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isActive ? TiyiNoteTheme.selectionBorder : Color.clear, lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? TiyiNoteTheme.activeUnderline : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, 10)
        }
    }
}

private struct WorkspaceSaveStateView: View {
    let state: LocalSaveState

    var body: some View {
        HStack(spacing: 5) {
            if case .saving = state {
                ProgressView()
                    .controlSize(.mini)
                    .tint(TiyiNoteTheme.textPrimary)
            } else {
                Image(systemName: symbol)
            }
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .frame(minWidth: 62)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .saved: "checkmark.circle.fill"
        case .saving: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch state {
        case .saved: "已保存"
        case .saving: "保存中"
        case .failed: "保存失败"
        }
    }

    private var color: Color {
        switch state {
        case .saved: TiyiNoteTheme.success
        case .saving: TiyiNoteTheme.textSecondary
        case .failed: TiyiNoteTheme.danger
        }
    }
}
