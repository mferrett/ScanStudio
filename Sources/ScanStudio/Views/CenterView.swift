import SwiftUI
import ImageCaptureCore

/// Area centrale: anteprima del piano con selezione, oppure la pagina selezionata.
struct CenterView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scanner: ScannerManager
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.settings.documentType == .idCard {
                IDWizardBar()
                Divider()
            }
            Group {
                if let page = model.selectedPage {
                    PageDetailView(page: page)
                        .id(page.id)
                } else {
                    ScanAreaView(scanner: scanner)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            statusBar
        }
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.image, .pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .alert("Scanner", isPresented: Binding(
            get: { scanner.errorMessage != nil },
            set: { if !$0 { scanner.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanner.errorMessage ?? "")
        }
    }

    // MARK: - Barra degli strumenti

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if scanner.isBusy {
                Button {
                    model.cancelScan()
                } label: {
                    Label("Interrompi", systemImage: "stop.circle")
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            Button {
                model.preview()
            } label: {
                Label("Anteprima", systemImage: "eye")
            }
            .help("Esegue una scansione rapida a bassa risoluzione (⇧⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!scanner.isReady || model.settings.source == .documentFeeder)

            Button {
                model.scan()
            } label: {
                Label("Scansiona", systemImage: "doc.viewfinder")
            }
            .help("Acquisisce la pagina e la aggiunge al documento (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!scanner.isReady)

            Button {
                showImporter = true
            } label: {
                Label("Importa", systemImage: "photo.badge.plus")
            }
            .help("Aggiunge immagini o PDF esistenti come pagine (⌘O)")
            .keyboardShortcut("o", modifiers: .command)

            Button {
                model.save()
            } label: {
                Label("Salva", systemImage: "square.and.arrow.down")
            }
            .help("Salva nel formato scelto (⌘S)")
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.pages.isEmpty)
        }
    }

    // MARK: - Intestazione

    private var header: some View {
        HStack(spacing: 10) {
            if model.selectedPage != nil, let index = model.selectedIndex {
                Button {
                    model.selectedPageID = nil
                } label: {
                    Label("Area di scansione", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text("Pagina \(index + 1) di \(model.pages.count)")
                    .font(.headline)

                Spacer()

                Picker("Modalità", selection: $model.selectedPageMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                Button { model.rotateSelected(-1) } label: { Image(systemName: "rotate.left") }
                    .help("Ruota a sinistra")
                Button { model.rotateSelected(1) } label: { Image(systemName: "rotate.right") }
                    .help("Ruota a destra")
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Elimina pagina")
            } else {
                Text("Area di scansione").font(.headline)
                Spacer()
                if model.settings.source != .documentFeeder {
                    Button {
                        model.detectDocument()
                    } label: {
                        if model.isDetecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Rileva documento", systemImage: "viewfinder")
                        }
                    }
                    .disabled(scanner.overviewImage == nil || model.isDetecting)
                    .help("Seleziona automaticamente il documento nell'anteprima")

                    Button {
                        model.selectWholeArea()
                    } label: {
                        Label("Tutto il piano", systemImage: "rectangle.dashed")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Barra di stato

    private var statusBar: some View {
        HStack(spacing: 8) {
            if scanner.isBusy || scanner.phase == .opening || scanner.phase == .configuring {
                ProgressView().controlSize(.small)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.pages.isEmpty {
                Text("\(model.pages.count) \(model.pages.count == 1 ? "pagina" : "pagine")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if scanner.scanners.isEmpty { return "Nessuno scanner rilevato" }
        switch scanner.phase {
        case .idle: return "Scanner non connesso"
        case .opening: return "Connessione allo scanner…"
        case .configuring: return "Configurazione della sorgente…"
        case .ready:
            if model.settings.documentType == .idCard {
                return model.idFront == nil
                    ? "Pronto — appoggia il FRONTE del documento e premi Scansiona"
                    : "Fronte acquisito — gira il documento, appoggia il RETRO e premi Scansiona"
            }
            return model.settings.source == .documentFeeder
                ? "Pronto — inserisci i fogli nell'alimentatore e premi Scansiona"
                : (scanner.overviewImage == nil
                   ? "Pronto — premi Anteprima per vedere il piano, oppure Scansiona"
                   : "Pronto — regola l'area e premi Scansiona")
        case .overview: return "Anteprima in corso…"
        case .scanning:
            return scanner.pagesInCurrentJob > 0
                ? "Scansione in corso… pagine ricevute: \(scanner.pagesInCurrentJob)"
                : "Scansione in corso…"
        }
    }
}

// MARK: - Wizard documento di identità

struct IDWizardBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            step(1, "Fronte", done: model.idFront != nil, active: model.idFront == nil)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            step(2, "Retro", done: false, active: model.idFront != nil)
            if let front = model.idFront {
                Image(decorative: ImageUtilities.downscale(front, maxSide: 120), scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
            }
            Spacer()
            if model.idFront != nil {
                Button("Ricomincia") { model.resetIDWizard() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func step(_ n: Int, _ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle\(active ? ".fill" : "")")
                .foregroundStyle(done ? Color.green : (active ? Color.accentColor : Color.secondary))
            Text(title).fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active || done ? .primary : .secondary)
        }
    }
}

// MARK: - Area di scansione

struct ScanAreaView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scanner: ScannerManager

    private var isFeeder: Bool { model.settings.source == .documentFeeder }

    private var contentSize: CGSize {
        if isFeeder, let page = model.settings.feederSize.inches { return page }
        if let ov = scanner.overviewImage { return CGSize(width: ov.width, height: ov.height) }
        let phys = scanner.physicalSize
        return phys.width > 0 && phys.height > 0 ? phys : CGSize(width: 8.27, height: 11.69)
    }

    var body: some View {
        GeometryReader { geo in
            let frame = fittedRect(content: contentSize,
                                   in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 28, dy: 28))
            ZStack(alignment: .topLeading) {
                Group {
                    if !isFeeder, let overview = scanner.overviewImage {
                        ProcessedImageView(source: overview,
                                           adjustments: model.defaultAdjustments,
                                           mode: model.settings.mode)
                    } else {
                        placeholder
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .background(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .position(x: frame.midX, y: frame.midY)

                if !isFeeder {
                    SelectionOverlay(selection: $model.settings.selection,
                                     imageFrame: frame,
                                     physicalSize: scanner.physicalSize,
                                     enabled: !scanner.isBusy)
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: isFeeder ? "tray.and.arrow.down" : "doc.viewfinder")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isFeeder ? "Alimentatore automatico" : "Nessuna anteprima")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(isFeeder
                 ? "Inserisci i fogli e premi Scansiona: ogni foglio diventa una pagina."
                 : "Premi Anteprima per vedere il contenuto del piano.\nPuoi già trascinare per selezionare l'area.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pagina

struct PageDetailView: View {
    let page: ScannedPage

    var body: some View {
        VStack(spacing: 8) {
            ProcessedImageView(source: page.preview,
                               adjustments: page.adjustments,
                               mode: page.mode,
                               quarterTurns: page.quarterTurns)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("\(page.full.width) × \(page.full.height) px · \(Int(page.dpi)) dpi · \(page.sizeDescription)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

#Preview("CenterView") {
    let model = AppModel()
    return CenterView(scanner: model.scanner)
        .environmentObject(model)
        .frame(width: 760, height: 840)
}
