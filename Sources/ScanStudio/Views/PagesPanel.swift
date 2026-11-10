import SwiftUI

/// Elenco delle pagine acquisite: selezione, riordino (trascinamento), rotazione, eliminazione.
struct PagesPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(localized("Pagine")).font(.headline)
                Spacer()
                Text("\(model.pages.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if model.pages.isEmpty {
                ContentUnavailableView(localized("Nessuna pagina"),
                                       systemImage: "doc.on.doc",
                                       description: Text(localized("Le pagine scansionate o importate appariranno qui.")))
            } else {
                List(selection: Binding(get: { model.selectedPageID }, set: { model.selectPageForViewing($0) })) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                        PageRow(page: page, number: index + 1)
                            .tag(page.id)
                            .contextMenu { contextMenu(for: page, index: index) }
                    }
                    .onMove { model.movePages(from: $0, to: $1) }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    model.deleteSelected()
                }
            }

            Divider()

            HStack {
                Button {
                    model.selectPageForViewing(nil)
                } label: {
                    Label(localized("Area di scansione"), systemImage: "viewfinder")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedPageID == nil)

                Spacer()

                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(localized("Elimina tutte le pagine"))
                .disabled(model.pages.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog(localized("Eliminare tutte le pagine?"), isPresented: $confirmDeleteAll) {
            Button(localized("Elimina tutte"), role: .destructive) { model.deleteAll() }
        } message: {
            Text(localized("L'operazione non può essere annullata."))
        }
    }

    @ViewBuilder
    private func contextMenu(for page: ScannedPage, index: Int) -> some View {
        Button(localized("Ruota a sinistra")) { model.rotate(page.id, by: -1) }
        Button(localized("Ruota a destra")) { model.rotate(page.id, by: 1) }
        Divider()
        Button(localized("Sposta su")) { model.movePage(page.id, by: -1) }
            .disabled(index == 0)
        Button(localized("Sposta giù")) { model.movePage(page.id, by: 1) }
            .disabled(index == model.pages.count - 1)
        Divider()
        Button(localized("Elimina"), role: .destructive) { model.deletePages([page.id]) }
    }
}

private struct PageRow: View {
    let page: ScannedPage
    let number: Int

    var body: some View {
        HStack(spacing: 10) {
            ProcessedImageView(source: page.thumbnail,
                               adjustments: page.adjustments,
                               mode: page.mode,
                               quarterTurns: page.quarterTurns)
                .frame(width: 52, height: 68)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedFormat("Pagina %lld", number))
                Text("\(Int(page.dpi)) dpi · \(page.mode.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

#Preview("PagesPanel") {
    PagesPanel()
        .environmentObject(AppModel())
        .frame(width: 230, height: 600)
}
