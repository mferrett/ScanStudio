import SwiftUI
import AppKit

/// Dialog per creare, modificare ed eliminare le cartelle di destinazione predefinite.
struct PresetsDialog: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list.frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                detail.frame(minWidth: 340)
            }
            Divider()
            HStack {
                Spacer()
                Button("Fine") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 380)
        .onAppear { selection = model.selectedPresetID ?? model.presets.first?.id }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.presets) { Text($0.name).tag($0.id) }
            }
            Divider()
            HStack(spacing: 4) {
                Button { add() } label: { Image(systemName: "plus") }
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = model.presets.firstIndex(where: { $0.id == selection }) {
            Form {
                TextField("Nome", text: $model.presets[index].name)
                LabeledContent("Cartella") {
                    HStack {
                        Text(model.presets[index].folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.presets[index].folderExists ? Color.primary : Color.red)
                        Spacer()
                        Button("Scegli…") { chooseFolder(for: index) }
                    }
                }
                TextField("Modello nome file", text: $model.presets[index].fileNamePattern)
                Text("Segnaposto: {tipo} (ricevuta, fattura…), {attività} (esercente riconosciuto), {data} (ggMMaaaa). Esempio: ricevuta Bar Roma - 11102026")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Modello predefinito") {
                        model.presets[index].fileNamePattern = DestinationPreset.defaultPattern
                    }
                    Spacer()
                    Button("Usa questa") {
                        model.selectedPresetID = model.presets[index].id
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.presets[index].fileNamePattern) { _, _ in model.refreshFileName() }
        } else {
            ContentUnavailableView("Nessuna destinazione",
                                   systemImage: "folder.badge.plus",
                                   description: Text("Premi + per aggiungere una cartella, ad esempio “Ricevute rimborsi”."))
        }
    }

    private func add() {
        guard let folder = pickFolder() else { return }
        let preset = DestinationPreset(name: folder.lastPathComponent, folderPath: folder.path)
        model.presets.append(preset)
        selection = preset.id
    }

    private func chooseFolder(for index: Int) {
        guard let folder = pickFolder(start: model.presets[index].folderURL) else { return }
        model.presets[index].folderPath = folder.path
    }

    private func removeSelected() {
        guard let id = selection, let index = model.presets.firstIndex(where: { $0.id == id }) else { return }
        if model.selectedPresetID == id { model.selectedPresetID = nil }
        model.presets.remove(at: index)
        selection = model.presets.first?.id
    }

    private func pickFolder(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}
