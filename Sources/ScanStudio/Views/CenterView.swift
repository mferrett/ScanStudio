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
                if scanner.isBusy {
                    ScanAreaView(scanner: scanner)
                } else if let page = model.selectedPage {
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
        .alert(localized("Scanner"), isPresented: Binding(
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
                    Label(localized("Interrompi"), systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(".", modifiers: .command)
            }

            Button {
                model.preview()
            } label: {
                Label(localized("Anteprima"), systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .help(localized("Esegue una scansione rapida a bassa risoluzione (⇧⌘P)"))
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!scanner.isReady || model.settings.source == .documentFeeder)

            Button {
                model.scan()
            } label: {
                Label(localized("Scansiona"), systemImage: "doc.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .labelStyle(.titleAndIcon)
            .help(localized("Acquisisce la pagina e la aggiunge al documento (⌘R)"))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!scanner.isReady)

            Button {
                showImporter = true
            } label: {
                Label(localized("Importa"), systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .help(localized("Aggiunge immagini o PDF esistenti come pagine (⌘O)"))
            .keyboardShortcut("o", modifiers: .command)

            Button {
                model.save()
            } label: {
                Label(localized("Salva"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .help(localized("Salva nel formato scelto (⌘S)"))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.pages.isEmpty)
        }
    }

    // MARK: - Intestazione

    private var header: some View {
        HStack(spacing: 10) {
            if model.selectedPage != nil, let index = model.selectedIndex {
                Button {
                    model.selectPageForViewing(nil)
                } label: {
                    Label(localized("Area di scansione"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text(localizedFormat("Pagina %lld di %lld", index + 1, model.pages.count))
                    .font(.headline)

                Spacer()

                Picker(localized("Modalità"), selection: $model.selectedPageMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                Button { model.rotateSelected(-1) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(localized("Ruota a sinistra"))
                    .help(localized("Ruota a sinistra"))
                Button { model.rotateSelected(1) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(localized("Ruota a destra"))
                    .help(localized("Ruota a destra"))
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(localized("Elimina pagina"))
                    .help(localized("Elimina pagina"))
            } else {
                Text(localized("Area di scansione")).font(.headline)
                Spacer()
                if model.settings.source != .documentFeeder {
                    Button {
                        model.detectDocument()
                    } label: {
                        if model.isDetecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(localized("Rileva documento"), systemImage: "viewfinder")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanner.overviewImage == nil || model.isDetecting || scanner.isBusy)
                    .help(localized("Seleziona automaticamente il documento nell'anteprima"))

                    Button {
                        model.selectWholeArea()
                    } label: {
                        Label(localized("Tutto il piano"), systemImage: "rectangle.dashed")
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanner.isBusy)
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
                Text(localizedFormat(model.pages.count == 1 ? "%lld pagina" : "%lld pagine", model.pages.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if scanner.scanners.isEmpty { return localized("Nessuno scanner rilevato") }
        switch scanner.phase {
        case .idle: return localized("Scanner non connesso")
        case .opening: return localized("Connessione allo scanner…")
        case .configuring: return localized("Configurazione della sorgente…")
        case .ready:
            if model.settings.documentType == .idCard {
                return model.idFront == nil
                    ? localized("Pronto — appoggia il FRONTE del documento e premi Scansiona")
                    : localized("Fronte acquisito — gira il documento, appoggia il RETRO e premi Scansiona")
            }
            return model.settings.source == .documentFeeder
                ? localized("Pronto — inserisci i fogli nell'alimentatore e premi Scansiona")
                : (scanner.overviewImage == nil
                   ? localized("Pronto — premi Anteprima per vedere il piano, oppure Scansiona")
                   : localized("Pronto — regola l'area e premi Scansiona"))
        case .overview: return localized("Anteprima in corso…")
        case .scanning:
            return scanner.pagesInCurrentJob > 0
                ? localizedFormat("Scansione in corso… pagine ricevute: %lld", scanner.pagesInCurrentJob)
                : localized("Scansione in corso…")
        }
    }
}

// MARK: - Wizard documento di identità

struct IDWizardBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            step(1, localized("Fronte"), done: model.idFront != nil, active: model.idFront == nil)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            step(2, localized("Retro"), done: false, active: model.idFront != nil)
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
                Button(localized("Ricomincia")) { model.resetIDWizard() }
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
        if scanner.phase == .scanning, let image = scanner.lastScannedPreview { return CGSize(width: image.width, height: image.height) }
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
                    if scanner.phase == .scanning, let image = scanner.lastScannedPreview {
                        ProcessedImageView(source: image, adjustments: model.defaultAdjustments, mode: model.settings.mode)
                    } else if !isFeeder, let overview = scanner.overviewImage {
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

                if !isFeeder && !scanner.isBusy {
                    SelectionOverlay(selection: $model.settings.selection,
                                     imageFrame: frame,
                                     physicalSize: scanner.physicalSize,
                                     enabled: !scanner.isBusy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if scanner.isBusy { scanningIndicator }
            }
        }
    }

    private var scanningIndicator: some View {
        VStack(spacing: 10) {
            if let progress = scanner.scanProgress, scanner.phase == .scanning {
                ProgressView(value: progress).frame(width: 190)
                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    .font(.subheadline.weight(.semibold))
            } else {
                ProgressView().controlSize(.large)
            }
            Text(scanner.phase == .overview ? localized("Acquisizione anteprima…") : localized("Scansione in corso…"))
                .font(.headline)
            if scanner.phase == .scanning {
                Text(scanner.pagesInCurrentJob == 0 ? localized("L’immagine sarà visibile quando la pagina sarà ricevuta.") : localizedFormat("Pagine ricevute: %lld", scanner.pagesInCurrentJob))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: isFeeder ? "tray.and.arrow.down" : "doc.viewfinder")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(scanner.isBusy ? localized("Acquisizione in corso") : (isFeeder ? localized("Alimentatore automatico") : localized("Nessuna anteprima")))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(scanner.isBusy ? localized("Attendi la risposta dello scanner.") : (isFeeder
                 ? localized("Inserisci i fogli e premi Scansiona: ogni foglio diventa una pagina.")
                 : localized("Premi Anteprima per vedere il contenuto del piano.\nPuoi già trascinare per selezionare l'area.")))
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
