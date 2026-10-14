import SwiftUI
import ImageCaptureCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scanner: ScannerManager
    @State private var showPresets = false

    private var isFeeder: Bool { model.settings.source == .documentFeeder }

    var body: some View {
        Form {
            scannerSection
            if !scanner.availableSources.isEmpty { sourceSection }
            scanSection
            exportSection
            adjustmentsSection
        }
        .formStyle(.grouped)
        .onChange(of: scanner.availableSources) { _, sources in
            guard !sources.isEmpty else { return }
            if !sources.contains(model.settings.source) {
                model.settings.source = sources.contains(.flatbed) ? .flatbed : sources[0]
            } else if scanner.activeSource != model.settings.source {
                // Sorgente ripristinata dall'ultimo avvio: la applica allo scanner
                scanner.switchSource(model.settings.source)
            }
        }
        .onChange(of: scanner.activeSource) { _, active in
            // Allinea l'interfaccia se il driver cambia sorgente da solo
            if let active, !scanner.isBusy, scanner.availableSources.isEmpty {
                model.settings.source = active
            }
        }
        .onChange(of: model.settings.documentType) { _, _ in
            model.resetIDWizard()
            model.refreshFileName()
        }
        .onChange(of: model.recognitionPage?.id) { _, _ in
            model.analyzeCurrentPage()
        }
        .sheet(isPresented: $showPresets) {
            PresetsDialog().environmentObject(model)
        }
        .onChange(of: model.settings.source) { _, source in
            scanner.switchSource(source)
        }
        .onChange(of: scanner.resolutions) { _, list in
            guard !list.isEmpty, !list.contains(model.settings.resolution) else { return }
            let target = 300
            model.settings.resolution = list.min(by: { abs($0 - target) < abs($1 - target) }) ?? list[0]
        }
    }

    // MARK: - Scanner

    private var scannerSection: some View {
        Section("Scanner") {
            if scanner.scanners.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Ricerca scanner in corso…").foregroundStyle(.secondary)
                }
                Text("Accendi lo scanner e verifica che sia visibile in Acquisizione Immagini.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Dispositivo", selection: Binding(
                    get: { scanner.selectedScanner },
                    set: { scanner.select($0) }
                )) {
                    ForEach(scanner.scanners, id: \.self) { device in
                        Text(scanner.displayName(of: device)).tag(Optional(device))
                    }
                }
                .disabled(scanner.isBusy)
                LabeledContent("Stato") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                        if scanner.phase == .idle {
                            Button("Riconnetti") { scanner.reconnect() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch scanner.phase {
        case .idle: return "Non connesso"
        case .opening: return "Connessione…"
        case .configuring: return "Configurazione…"
        case .ready: return "Pronto"
        case .overview: return "Anteprima…"
        case .scanning: return "Scansione…"
        }
    }

    private var statusColor: Color {
        switch scanner.phase {
        case .ready: return .green
        case .overview, .scanning, .opening, .configuring: return .orange
        case .idle: return .gray
        }
    }

    // MARK: - Sorgente

    private var sourceSection: some View {
        Section("Sorgente") {
            Picker("Sorgente", selection: $model.settings.source) {
                ForEach(scanner.availableSources, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .disabled(scanner.isBusy)

            if isFeeder {
                Picker("Formato pagina", selection: $model.settings.feederSize) {
                    ForEach(FeederPageSize.allCases) { Text($0.label).tag($0) }
                }
                if scanner.supportsDuplex {
                    Toggle("Fronte/retro", isOn: $model.settings.duplex)
                }
                if let loaded = scanner.documentLoaded {
                    LabeledContent("Fogli inseriti", value: loaded ? "Sì" : "No")
                }
            }
        }
    }

    // MARK: - Scansione

    private var scanSection: some View {
        Section("Scansione") {
            Picker("Documento", selection: $model.settings.documentType) {
                ForEach(DocumentType.allCases) { Text($0.label).tag($0) }
            }
            .disabled(scanner.isBusy)
            if model.settings.documentType == .idCard {
                Toggle("Ritaglia automaticamente", isOn: $model.settings.idAutoCrop)
                Text("Scansiona il fronte, poi il retro: le due facce vengono unite in un'unica pagina, una sopra l'altra.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Modalità", selection: $model.settings.mode) {
                ForEach(ColorMode.allCases) { Text($0.longLabel).tag($0) }
            }

            Picker("Risoluzione", selection: $model.settings.resolution) {
                ForEach(resolutionChoices, id: \.self) { Text("\($0) dpi").tag($0) }
            }

            if !isFeeder {
                LabeledContent("Area") {
                    Text(areaDescription).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resolutionChoices: [Int] {
        var list = scanner.resolutions.isEmpty ? [75, 150, 200, 300, 600, 1200] : scanner.resolutions
        if !list.contains(model.settings.resolution) { list.append(model.settings.resolution); list.sort() }
        return list
    }

    private var areaDescription: String {
        let sel = model.settings.selection
        let wIn = sel.width * scanner.physicalSize.width
        let hIn = sel.height * scanner.physicalSize.height
        let px = "\(Int(wIn * CGFloat(model.settings.resolution))) × \(Int(hIn * CGFloat(model.settings.resolution))) px"
        return px
    }

    // MARK: - Regolazioni

    private var adjustmentsSection: some View {
        Section {
            let mode = model.editingMode
            SliderRow(title: "Luminosità", value: $model.editingAdjustments.brightness, range: -100...100)
            SliderRow(title: "Contrasto", value: $model.editingAdjustments.contrast, range: -100...100)
            SliderRow(title: "Brillantezza", value: $model.editingAdjustments.exposure, range: -100...100)
            SliderRow(title: "Toni medi (gamma)", value: $model.editingAdjustments.gamma, range: -100...100)
            if mode == .color {
                SliderRow(title: "Saturazione", value: $model.editingAdjustments.saturation, range: -100...100)
            }
            SliderRow(title: "Nitidezza", value: $model.editingAdjustments.sharpness, range: 0...100)
            SliderRow(title: "Riduzione rumore", value: $model.editingAdjustments.noiseReduction, range: 0...100)
            if mode == .blackWhite {
                SliderRow(title: "Soglia bianco/nero", value: $model.editingAdjustments.threshold,
                          range: 0...100, defaultValue: 50)
            }
            Toggle("Miglioramento automatico", isOn: $model.editingAdjustments.autoEnhance)
            Toggle("Inverti (negativo)", isOn: $model.editingAdjustments.invert)

            HStack {
                Button("Ripristina") { model.resetAdjustments() }
                Spacer()
                if model.selectedPage != nil && model.pages.count > 1 {
                    Button("Applica a tutte") { model.applyAdjustmentsToAll() }
                }
            }
        } header: {
            if let index = model.selectedIndex {
                Text("Regolazioni — pagina \(index + 1)")
            } else {
                Text("Regolazioni — nuove scansioni")
            }
        }
    }

    // MARK: - Salvataggio

    private var exportSection: some View {
        Section("Salvataggio") {
            HStack {
                Picker("Destinazione", selection: $model.selectedPresetID) {
                    Text("Chiedi ogni volta").tag(UUID?.none)
                    if !model.presets.isEmpty { Divider() }
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button {
                    showPresets = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("Gestisci le cartelle di destinazione")
            }
            if let preset = model.selectedPreset {
                Text(preset.folderExists ? preset.folderPath : "⚠︎ Cartella non trovata: \(preset.folderPath)")
                    .font(.caption)
                    .foregroundStyle(preset.folderExists ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                TextField("Nome file", text: Binding(get: { model.fileName }, set: { model.setFileName($0) }))
                    .textFieldStyle(.roundedBorder)
                Button {
                    model.restoreSuggestedFileName()
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .help("Ripropone il nome in base al documento riconosciuto")
                .disabled(model.pages.isEmpty)
            }

            Picker("Formato", selection: $model.exportOptions.format) {
                ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            if model.exportOptions.format == .pdf {
                Toggle("Compressione JPEG", isOn: $model.exportOptions.pdfUseJPEG)
                Toggle("Testo ricercabile (OCR)", isOn: $model.exportOptions.ocr)
            }
            if model.exportOptions.format == .jpeg
                || (model.exportOptions.format == .pdf && model.exportOptions.pdfUseJPEG) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Qualità")
                        Spacer()
                        Text("\(Int(model.exportOptions.jpegQuality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.exportOptions.jpegQuality, in: 0.3...1.0).controlSize(.small)
                }
            }
            Picker("Pagine", selection: $model.exportOptions.scope) {
                ForEach(ExportScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                model.save()
            } label: {
                Label("Salva…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.pages.isEmpty)
        }
    }
}

#Preview("SidebarView") {
    let model = AppModel()
    return SidebarView(scanner: model.scanner)
        .environmentObject(model)
        .frame(width: 400, height: 840)
}
