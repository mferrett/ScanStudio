import SwiftUI
import ImageCaptureCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scanner: ScannerManager
    @State private var showPresets = false
    private enum SidebarTab: String, CaseIterable, Identifiable {
        case scan = "Scansione", adjustments = "Regolazioni"
        var id: String { rawValue }
    }
    @State private var selectedTab: SidebarTab = .scan

    private var isFeeder: Bool { model.settings.source == .documentFeeder }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sezione", selection: $selectedTab) {
                ForEach(SidebarTab.allCases) { tab in Text(localized(tab.rawValue)).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            Form {
                switch selectedTab {
                case .scan:
                    scannerSection
                    if !scanner.availableSources.isEmpty { sourceSection }
                    scanSection
                    exportSection
                case .adjustments:
                    adjustmentsSection
                }
            }
            .formStyle(.grouped)
            Divider()
            Button {
                model.save()
            } label: {
                Label(localized("Salva…"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.pages.isEmpty)
            .padding(12)
        }
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
            model.analyzeCurrentPage()
        }
        .task(id: model.recognitionKey) {
            // Le regolazioni cambiano spesso durante il trascinamento degli slider.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
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
        Section(localized("Scanner")) {
            if scanner.scanners.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized("Ricerca scanner in corso…")).foregroundStyle(.secondary)
                }
                Text(localized("Accendi lo scanner e verifica che sia visibile in Acquisizione Immagini."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(localized("Dispositivo"), selection: Binding(
                    get: { scanner.selectedScanner },
                    set: { scanner.select($0) }
                )) {
                    ForEach(scanner.scanners, id: \.self) { device in
                        Text(scanner.displayName(of: device)).tag(Optional(device))
                    }
                }
                .disabled(scanner.isBusy)
                LabeledContent(localized("Stato")) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                        if scanner.phase == .idle {
                            Button(localized("Riconnetti")) { scanner.reconnect() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch scanner.phase {
        case .idle: return localized("Non connesso")
        case .opening: return localized("Connessione…")
        case .configuring: return localized("Configurazione…")
        case .ready: return localized("Pronto")
        case .overview: return localized("Anteprima…")
        case .scanning: return localized("Scansione…")
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
        Section(localized("Sorgente")) {
            Picker(localized("Sorgente"), selection: $model.settings.source) {
                ForEach(scanner.availableSources, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .disabled(scanner.isBusy)

            if isFeeder {
                Picker(localized("Formato pagina"), selection: $model.settings.feederSize) {
                    ForEach(FeederPageSize.allCases) { Text($0.label).tag($0) }
                }
                if scanner.supportsDuplex {
                    Toggle(localized("Fronte/retro"), isOn: $model.settings.duplex)
                }
                if let loaded = scanner.documentLoaded {
                    LabeledContent(localized("Fogli inseriti"), value: loaded ? localized("Sì") : localized("No"))
                }
            }
        }
    }

    // MARK: - Scansione

    private var scanSection: some View {
        Section(localized("Scansione")) {
            Picker(localized("Documento"), selection: $model.settings.documentType) {
                ForEach(DocumentType.allCases) { Text($0.label).tag($0) }
            }
            .disabled(scanner.isBusy)
            if model.settings.documentType == .idCard {
                Toggle(localized("Ritaglia automaticamente"), isOn: $model.settings.idAutoCrop)
                Text(localized("Scansiona il fronte, poi il retro: le due facce vengono unite in un'unica pagina, una sopra l'altra."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.settings.source == .flatbed && model.settings.documentType == .standard {
                Toggle(localized("Scansione multipla (multi-crop)"), isOn: $model.settings.multiCrop)
                    .disabled(scanner.isBusy)
                if model.settings.multiCrop {
                    Text(localized("Acquisisce tutto il piano e separa gli elementi rettangolari riconosciuti."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.multiCropOriginal != nil {
                    Button(localized("Aggiungi scansione completa")) { model.addMultiCropOriginal() }
                        .help(localized("Recupera il piano intero se un elemento non è stato rilevato."))
                }
            }

            Picker(localized("Modalità"), selection: $model.settings.mode) {
                ForEach(ColorMode.allCases) { Text($0.longLabel).tag($0) }
            }

            HStack(spacing: 8) {
                Picker(localized("Risoluzione"), selection: $model.settings.resolution) {
                    ForEach(resolutionChoices, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                if !isFeeder {
                    Spacer(minLength: 0)
                    Text(localizedFormat("Area %@", areaDescription))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(localizedFormat("Area: %@", areaDescription))
                }
            }

            if let status = model.previewRecognitionStatus {
                LabeledContent(localized("Tipo anteprima")) {
                    HStack {
                        Text(status).foregroundStyle(.secondary)
                        if model.previewAnalysisRunning { ProgressView().controlSize(.small) }
                    }
                }
                Text(localized("Il tipo è stimato sull’intera anteprima; la scansione finale viene analizzata separatamente."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var resolutionChoices: [Int] {
        var list = scanner.resolutions.isEmpty ? [75, 150, 200, 300, 600, 1200] : scanner.resolutions
        if !list.contains(model.settings.resolution) { list.append(model.settings.resolution); list.sort() }
        return list
    }

    private var areaDescription: String {
        let usesFullBed = model.settings.multiCrop && model.settings.source == .flatbed && model.settings.documentType == .standard
        let sel = usesFullBed ? CGRect(x: 0, y: 0, width: 1, height: 1) : model.settings.selection
        let wIn = sel.width * scanner.physicalSize.width
        let hIn = sel.height * scanner.physicalSize.height
        let px = "\(Int(wIn * CGFloat(model.settings.resolution))) × \(Int(hIn * CGFloat(model.settings.resolution))) px"
        return px
    }

    // MARK: - Regolazioni

    private var adjustmentsSection: some View {
        Section {
            let mode = model.editingMode
            Toggle(localized("Raddrizzamento automatico"), isOn: $model.editingAdjustments.advanced.deskew)
            SliderRow(title: localized("Riduzione retino"), value: $model.editingAdjustments.advanced.descreen, range: 0...100)
            Toggle(localized("Riduci polvere (software)"), isOn: $model.editingAdjustments.advanced.dustRemoval)
                .help(localized("Filtro mediano: può ammorbidire i dettagli; non usa infrarossi."))
            Toggle(localized("Ripristino colore (software)"), isOn: $model.editingAdjustments.advanced.restoreColors)
            SliderRow(title: localized("Ombra rilegatura"), value: $model.editingAdjustments.advanced.gutter, range: 0...100)
            if model.editingAdjustments.advanced.gutter > 0 {
                Toggle(localized("Dorso a destra"), isOn: $model.editingAdjustments.advanced.gutterOnRight)
            }
            SliderRow(title: localized("Luminosità"), value: $model.editingAdjustments.brightness, range: -100...100)
            SliderRow(title: localized("Contrasto"), value: $model.editingAdjustments.contrast, range: -100...100)
            SliderRow(title: localized("Brillantezza"), value: $model.editingAdjustments.exposure, range: -100...100)
            SliderRow(title: localized("Toni medi (gamma)"), value: $model.editingAdjustments.gamma, range: -100...100)
            if mode == .color {
                SliderRow(title: localized("Saturazione"), value: $model.editingAdjustments.saturation, range: -100...100)
            }
            SliderRow(title: localized("Nitidezza"), value: $model.editingAdjustments.sharpness, range: 0...100)
            SliderRow(title: localized("Riduzione rumore"), value: $model.editingAdjustments.noiseReduction, range: 0...100)
            if mode == .blackWhite {
                SliderRow(title: localized("Soglia bianco/nero"), value: $model.editingAdjustments.threshold,
                          range: 0...100, defaultValue: 50)
            }
            Toggle(localized("Miglioramento automatico"), isOn: $model.editingAdjustments.autoEnhance)
            Toggle(localized("Inverti (negativo)"), isOn: $model.editingAdjustments.invert)

            HStack {
                Button(localized("Ripristina")) { model.resetAdjustments() }
                Spacer()
                if model.selectedPage != nil && model.pages.count > 1 {
                    Button(localized("Applica a tutte")) { model.applyAdjustmentsToAll() }
                }
            }
        } header: {
            if let index = model.selectedIndex {
                Text(localizedFormat("Regolazioni — pagina %lld", index + 1))
            } else {
                Text(localized("Regolazioni — nuove scansioni"))
            }
        }
    }

    // MARK: - Salvataggio

    private var exportSection: some View {
        Section(localized("Salvataggio")) {
            HStack {
                Picker(localized("Destinazione"), selection: $model.selectedPresetID) {
                    Text(localized("Chiedi ogni volta")).tag(UUID?.none)
                    if !model.presets.isEmpty { Divider() }
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button {
                    showPresets = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help(localized("Gestisci le cartelle di destinazione"))
            }
            if let preset = model.selectedPreset {
                Text(preset.folderExists ? preset.folderPath : localizedFormat("⚠︎ Cartella non trovata: %@", preset.folderPath))
                    .font(.caption)
                    .foregroundStyle(preset.folderExists ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Picker(localized("Tipo documento"), selection: Binding(
                get: { model.selectedKindOverride },
                set: { model.selectedKindOverride = $0 }
            )) {
                Text(localized("Automatico")).tag(DocumentKind?.none)
                ForEach(DocumentKind.allCases.filter { $0 != .unknown }) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
                Text(localized("Documento generico")).tag(Optional(DocumentKind.unknown))
            }
            .disabled(!model.canChooseDocumentKind)
            Text(model.recognitionStatus).font(.caption).foregroundStyle(.secondary)
            TextField(localized("Nome file"), text: Binding(get: { model.fileName }, set: { model.setFileName($0) }))
                .textFieldStyle(.roundedBorder)

            Picker(localized("Formato"), selection: $model.exportOptions.format) {
                ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            if model.exportOptions.format.isPDF {
                Toggle(localized("Compressione JPEG"), isOn: $model.exportOptions.pdfUseJPEG)
            }
            Toggle(localized("Crea anche Markdown strutturato (.md)"), isOn: $model.exportOptions.exportMarkdown)
                .help(localized("Salva un file separato con la struttura riconosciuta da Vision e, se disponibile, dal modello locale Apple Intelligence."))
            if model.exportOptions.format == .jpeg
                || (model.exportOptions.format.isPDF && model.exportOptions.pdfUseJPEG) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(localized("Qualità"))
                        Spacer()
                        Text("\(Int(model.exportOptions.jpegQuality * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.exportOptions.jpegQuality, in: 0.3...1.0).controlSize(.small)
                }
            }
            Picker(localized("Pagine"), selection: $model.exportOptions.scope) {
                ForEach(ExportScope.allCases) { scope in
                    Text(scope.label).tag(scope).disabled(scope == .multiCrop && model.multiCropPageIDs.isEmpty)
                }
            }
            .pickerStyle(.segmented)

        }
    }
}

#Preview("SidebarView") {
    let model = AppModel()
    return SidebarView(scanner: model.scanner)
        .environmentObject(model)
        .frame(width: 400, height: 840)
}
