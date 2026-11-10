import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// Stato dell'applicazione: pagine acquisite, impostazioni, regolazioni, esportazione.
final class AppModel: ObservableObject {

    @Published var pages: [ScannedPage] = []
    @Published var selectedPageID: UUID?
    @Published var settings = ScanSettings()
    @Published var defaultAdjustments = Adjustments()
    @Published var exportOptions = ExportOptions()
    @Published var alertMessage: String?
    @Published var busyMessage: String?
    @Published var busyProgress: Double = 0
    @Published var isDetecting = false
    @Published private(set) var previewInfo: DocumentInfo?
    @Published private(set) var previewAnalysisRunning = false
    @Published private(set) var previewAnalysisFailed = false
    private var previewGeneration = UUID()

    /// Wizard documento di identità: fronte già acquisito, in attesa del retro
    @Published private(set) var idFront: CGImage?
    private var idFrontDPI: Double = 300

    // Destinazioni predefinite e nome file proposto
    @Published var presets: [DestinationPreset] = [] {
        didSet { Self.persist(presets, key: Self.presetsKey) }
    }
    @Published var selectedPresetID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPresetID?.uuidString, forKey: Self.selectedPresetKey)
            refreshFileName()
        }
    }
    @Published private(set) var fileName = ""
    private var fileNameEdited = false
    private var fileNameEditVersion = 0
    private var previewRequestedEditVersion: Int?
    @Published private var previewNamingActive = false
    @Published private var previewKindOverride: DocumentKind?
    private var persistenceSubscriptions: [AnyCancellable] = []
    struct RecognitionKey: Hashable {
        let id: UUID
        let adjustments: Adjustments
        let mode: ColorMode
        let turns: Int
        init(_ page: ScannedPage) { id = page.id; adjustments = page.adjustments; mode = page.mode; turns = page.quarterTurns }
    }
    @Published private var recognized: [RecognitionKey: DocumentInfo] = [:]
    @Published private var recognizing: Set<RecognitionKey> = []
    @Published private var recognitionFailures: Set<RecognitionKey> = []
    @Published private var kindOverrides: [UUID: DocumentKind] = [:]
    var recognitionKey: RecognitionKey? { recognitionPage.map(RecognitionKey.init) }
    var canChooseDocumentKind: Bool { previewNamingActive || recognitionPage != nil }
    var recognizedKind: DocumentKind? {
        if previewNamingActive { return previewInfo?.kind }
        guard let page = recognitionPage else { return nil }
        if settings.documentType == .idCard { return .idCard }
        return recognized[RecognitionKey(page)]?.kind
    }
    var selectedKindOverride: DocumentKind? {
        get { previewNamingActive ? previewKindOverride : recognitionPage.flatMap { kindOverrides[$0.id] } }
        set {
            if previewNamingActive { previewKindOverride = newValue }
            else {
                guard let page = recognitionPage else { return }
                kindOverrides[page.id] = newValue
            }
            refreshFileName()
        }
    }
    var recognitionStatus: String {
        if previewNamingActive { return previewRecognitionStatus ?? localized("In attesa dell’anteprima") }
        guard let key = recognitionKey else { return localized("Nessuna pagina da analizzare") }
        if settings.documentType == .idCard { return localized("Tipo impostato dalla scansione documento d’identità") }
        if recognizing.contains(key) {
            if let kind = recognized[key]?.kind, kind != .unknown { return localizedFormat("Suggerimento automatico: %@", kind.fileLabel) }
            return recognized[key] == nil ? localized("Lettura del documento…") : localized("Tipo non ancora riconosciuto · analisi approfondita…")
        }
        if recognitionFailures.contains(key) { return localized("Riconoscimento non riuscito: scegli il tipo manualmente") }
        guard let kind = recognized[key]?.kind else { return localized("Analisi in preparazione…") }
        return kind == .unknown ? localized("Tipo non riconosciuto: puoi selezionarlo") : localizedFormat("Suggerimento automatico: %@", kind.fileLabel)
    }

    private static let presetsKey = "destinationPresets"
    private static let selectedPresetKey = "selectedDestinationPreset"

    let scanner: ScannerManager
    private var modeForCurrentScan: ColorMode = .color
    private var multiCropForCurrentScan = false
    @Published private(set) var multiCropOriginal: CGImage?
    @Published private(set) var multiCropPageIDs: [UUID] = []
    private var multiCropOriginalDPI: Double = 300
    private var multiCropOriginalMode: ColorMode = .color
    private var multiCropOriginalAdjustments = Adjustments()

    init(scanner: ScannerManager = ScannerManager(), persistSettings: Bool = true) {
        self.scanner = scanner
        if persistSettings { loadPersistedSettings() }
        if persistSettings, let data = UserDefaults.standard.data(forKey: Self.presetsKey),
           let saved = try? JSONDecoder().decode([DestinationPreset].self, from: data) {
            presets = saved
        }
        if persistSettings, let raw = UserDefaults.standard.string(forKey: Self.selectedPresetKey),
           let id = UUID(uuidString: raw), presets.contains(where: { $0.id == id }) {
            selectedPresetID = id
        }
        scanner.onPageScanned = { [weak self] image, dpi in
            guard let self else { return }
            if self.settings.documentType == .idCard {
                self.handleIDCardScan(image, dpi: dpi)
                return
            }
            if self.multiCropForCurrentScan {
                self.processMultiCrop(image, dpi: dpi)
            } else {
                self.addPage(image, dpi: dpi, mode: self.modeForCurrentScan, adjustments: self.defaultAdjustments)
                self.selectedPageID = self.pages.last?.id
            }
        }
        scanner.onOverviewCompleted = { [weak self] image in self?.analyzeOverview(image) }
        scanner.onOverviewCleared = { [weak self] in self?.clearOverviewAnalysis() }
        if persistSettings { persistenceSubscriptions = startPersistingSettings() }
    }

    // MARK: - Pagina selezionata

    var selectedIndex: Int? {
        guard let id = selectedPageID else { return nil }
        return pages.firstIndex { $0.id == id }
    }

    var selectedPage: ScannedPage? {
        selectedIndex.map { pages[$0] }
    }

    /// Le regolazioni modificate dal pannello: quelle della pagina selezionata
    /// oppure quelle applicate alle nuove scansioni.
    var editingAdjustments: Adjustments {
        get { selectedIndex.map { pages[$0].adjustments } ?? defaultAdjustments }
        set {
            if let i = selectedIndex { pages[i].adjustments = newValue } else { defaultAdjustments = newValue }
        }
    }

    var editingMode: ColorMode {
        selectedPage?.mode ?? settings.mode
    }

    var selectedPageMode: ColorMode {
        get { selectedPage?.mode ?? .color }
        set { if let i = selectedIndex { pages[i].mode = newValue } }
    }

    // MARK: - Scansione

    func preview() {
        clearOverviewAnalysis()
        previewNamingActive = true
        previewRequestedEditVersion = fileNameEditVersion
        selectedPageID = nil
        scanner.requestOverview(settings: settings)
    }

    private func clearOverviewAnalysis() {
        previewGeneration = UUID()
        previewNamingActive = false
        previewKindOverride = nil
        previewInfo = nil
        previewAnalysisRunning = false
        previewAnalysisFailed = false
    }

    /// Analyses the full overview without replacing or persisting the scanned pages.
    func analyzeOverview(_ image: CGImage) {
        let generation = UUID()
        previewGeneration = generation
        previewNamingActive = true
        previewKindOverride = nil
        if previewRequestedEditVersion == fileNameEditVersion { fileNameEdited = false }
        previewRequestedEditVersion = nil
        previewInfo = nil
        previewAnalysisFailed = false
        previewAnalysisRunning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let ocr = try await DocumentOCR.recognize(image)
                let initial = DocumentRecognizer.analyzeQuick(ocr)
                await MainActor.run {
                    guard let self, self.previewGeneration == generation else { return }
                    self.previewInfo = initial
                    if self.previewNamingActive { self.refreshFileName() }
                }
                let refined = await DocumentRecognizer.refine(ocr, initial: initial)
                await MainActor.run {
                    guard let self, self.previewGeneration == generation else { return }
                    self.previewInfo = refined
                    self.previewAnalysisRunning = false
                    if self.previewNamingActive { self.refreshFileName() }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.previewGeneration == generation else { return }
                    self.previewAnalysisRunning = false
                    self.previewAnalysisFailed = true
                }
            }
        }
    }

    var previewRecognitionStatus: String? {
        if previewAnalysisFailed { return localized("Analisi dell’anteprima non riuscita") }
        guard let info = previewInfo else { return previewAnalysisRunning ? localized("Lettura dell’anteprima…") : nil }
        if info.kind == .unknown {
            return previewAnalysisRunning ? localized("Tipo non ancora riconosciuto · analisi approfondita…") : localized("Tipo non riconosciuto nell’anteprima")
        }
        return localizedFormat("Anteprima: %@", info.kind.displayName)
    }

    func scan() {
        guard busyMessage == nil else { return }
        modeForCurrentScan = settings.mode
        multiCropForCurrentScan = settings.multiCrop && settings.source == .flatbed && settings.documentType == .standard
        if !multiCropForCurrentScan {
            if exportOptions.scope == .multiCrop { exportOptions.scope = .all }
        }
        var scanSettings = settings
        if multiCropForCurrentScan { scanSettings.selection = CGRect(x: 0, y: 0, width: 1, height: 1) }
        scanner.scan(settings: scanSettings)
    }

    func processMultiCrop(_ image: CGImage, dpi: Double) {
        let mode = modeForCurrentScan
        let adjustments = defaultAdjustments
        multiCropOriginal = image
        multiCropOriginalDPI = dpi
        multiCropOriginalMode = mode
        multiCropOriginalAdjustments = adjustments
        busyMessage = localized("Rilevamento degli elementi…")
        busyProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            let parts = ImageUtilities.splitDocuments(image)
            await MainActor.run {
                guard let self else { return }
                self.busyMessage = nil
                guard !parts.isEmpty else {
                    self.multiCropPageIDs = []
                    if self.exportOptions.scope == .multiCrop { self.exportOptions.scope = .all }
                    self.multiCropOriginal = nil
                    self.addPage(image, dpi: dpi, mode: mode, adjustments: adjustments)
                    self.selectedPageID = self.pages.last?.id
                    self.alertMessage = localized("Nessun elemento rettangolare rilevato. È stata conservata la scansione completa.")
                    return
                }
                var newIDs: [UUID] = []
                for part in parts {
                    self.addPage(part, dpi: dpi, mode: mode, adjustments: adjustments)
                    if let id = self.pages.last?.id { newIDs.append(id) }
                }
                self.multiCropPageIDs = newIDs
                self.selectedPageID = self.pages.last?.id
                self.exportOptions.format = self.exportOptions.format.singlePageVariant
                self.exportOptions.scope = .multiCrop
                self.alertMessage = localizedFormat("Rilevati %lld elementi. Verifica i ritagli prima di salvarli. La scansione completa resta disponibile.", parts.count)
            }
        }
    }

    func addMultiCropOriginal() {
        guard let image = multiCropOriginal else { return }
        addPage(image, dpi: multiCropOriginalDPI, mode: multiCropOriginalMode, adjustments: multiCropOriginalAdjustments)
        selectedPageID = pages.last?.id
        multiCropOriginal = nil
    }

    func cancelScan() {
        scanner.cancel()
    }

    func selectWholeArea() {
        settings.selection = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func detectDocument() {
        guard let overview = scanner.overviewImage else { return }
        isDetecting = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let rect = ImageUtilities.detectDocument(in: overview)
            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false
                if let rect {
                    self.settings.selection = rect
                } else {
                    self.alertMessage = localized("Nessun documento riconosciuto nell'anteprima. Seleziona l'area manualmente.")
                }
            }
        }
    }

    // MARK: - Destinazioni e nome file

    private static func persist(_ presets: [DestinationPreset], key: String) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }

    var selectedPreset: DestinationPreset? {
        presets.first { $0.id == selectedPresetID }
    }

    var multiCropPages: [ScannedPage] { pages.filter { multiCropPageIDs.contains($0.id) } }

    /// Pagina da cui ricavare il tipo di documento e l'attività
    var recognitionPage: ScannedPage? {
        switch exportOptions.scope {
        case .selected: return selectedPage
        case .multiCrop: return multiCropPages.first
        case .all: return pages.first
        }
    }

    /// Modifica manuale del nome: da qui in poi il suggerimento non lo sovrascrive più
    func setFileName(_ name: String) {
        fileNameEditVersion += 1
        fileName = name
        fileNameEdited = !name.isEmpty
        if name.isEmpty { refreshFileName() }
    }

    func analyzeCurrentPage() {
        guard let page = recognitionPage else {
            if !previewNamingActive && !fileNameEdited { fileName = "" }
            return
        }
        let key = RecognitionKey(page)
        if recognized[key] != nil || settings.documentType == .idCard {
            refreshFileName()
            return
        }
        guard recognizing.insert(key).inserted else { return }
        recognitionFailures.remove(key)
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await DocumentOCRCache.shared.recognize(page)
                let initial = DocumentRecognizer.analyzeQuick(result)
                await MainActor.run {
                    guard let self, let current = self.pages.first(where: { $0.id == key.id }), RecognitionKey(current) == key else { return }
                    self.recognized = self.recognized.filter { $0.key.id != key.id }
                    self.recognized[key] = initial
                    if self.recognitionKey == key { self.refreshFileName() }
                }
                let info = await DocumentRecognizer.refine(result, initial: initial)
                await MainActor.run {
                    guard let self else { return }
                    self.recognizing.remove(key)
                    guard let current = self.pages.first(where: { $0.id == key.id }), RecognitionKey(current) == key else { return }
                    self.recognized[key] = info
                    if self.recognitionKey == key { self.refreshFileName() }
                }
                let enriched = await DocumentRecognizer.enrich(result, initial: info)
                await MainActor.run {
                    guard let self, let current = self.pages.first(where: { $0.id == key.id }), RecognitionKey(current) == key else { return }
                    self.recognized[key] = enriched
                    if self.recognitionKey == key { self.refreshFileName() }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.recognizing.remove(key)
                    self.recognitionFailures.insert(key)
                }
            }
        }
    }

    func refreshFileName() {
        guard !fileNameEdited else { return }
        var info: DocumentInfo
        if previewNamingActive {
            guard let previewInfo else { return }
            info = previewInfo
            if settings.documentType == .idCard { info = DocumentInfo(kind: .idCard, business: nil) }
            if let override = previewKindOverride {
                if override != info.kind { info.business = nil }
                info.kind = override
            }
        } else {
            guard let page = recognitionPage else { fileName = ""; return }
            info = recognized[RecognitionKey(page)] ?? DocumentInfo()
            if settings.documentType == .idCard { info = DocumentInfo(kind: .idCard, business: nil) }
            if let override = kindOverrides[page.id] {
                if override != info.kind { info.business = nil }
                info.kind = override
            }
        }
        fileName = FileNameBuilder.build(pattern: selectedPreset?.fileNamePattern ?? DestinationPreset.defaultPattern,
                                         kind: info.kind.fileLabel, business: info.business, date: info.date ?? Date())
    }

    /// A deliberate page selection uses that page's metadata instead of the last overview.
    func selectPageForViewing(_ id: UUID?) {
        previewNamingActive = id == nil && previewInfo != nil
        selectedPageID = id
        refreshFileName()
    }

    /// URL libero nella cartella (aggiunge " 2", " 3"… se il file esiste già)
    private func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    // MARK: - Documento di identità (wizard fronte/retro)

    func resetIDWizard() {
        idFront = nil
    }

    private func handleIDCardScan(_ image: CGImage, dpi: Double) {
        guard let front = idFront else {
            idFront = image
            idFrontDPI = dpi
            return
        }
        let back = image
        let frontDPI = idFrontDPI
        let crop = settings.idAutoCrop
        let mode = modeForCurrentScan
        let adjustments = defaultAdjustments
        idFront = nil
        busyMessage = localized("Composizione del documento…")
        busyProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            let composed = IDCardComposer.compose(front: front, frontDPI: frontDPI,
                                                  back: back, backDPI: dpi, autoCrop: crop)
            await MainActor.run {
                guard let self else { return }
                self.busyMessage = nil
                if let composed {
                    self.addPage(composed, dpi: max(frontDPI, dpi), mode: mode, adjustments: adjustments)
                    self.selectedPageID = self.pages.last?.id
                } else {
                    self.alertMessage = localized("Impossibile comporre la pagina del documento.")
                }
            }
        }
    }

    // MARK: - Pagine

    func addPage(_ image: CGImage, dpi: Double, mode: ColorMode, adjustments: Adjustments) {
        let page = ScannedPage(full: image,
                               preview: ImageUtilities.downscale(image, maxSide: 2000),
                               thumbnail: ImageUtilities.downscale(image, maxSide: 220),
                               dpi: dpi,
                               mode: mode,
                               adjustments: adjustments)
        pages.append(page)
    }

    func deletePages(_ ids: Set<UUID>) {
        pages.removeAll { ids.contains($0.id) }
        multiCropPageIDs.removeAll { ids.contains($0) }
        if multiCropPageIDs.isEmpty && exportOptions.scope == .multiCrop { exportOptions.scope = .all }
        recognized = recognized.filter { !ids.contains($0.key.id) }
        kindOverrides = kindOverrides.filter { !ids.contains($0.key) }
        recognitionFailures = recognitionFailures.filter { !ids.contains($0.id) }
        Task { await DocumentOCRCache.shared.remove(ids) }
        if let id = selectedPageID, ids.contains(id) { selectedPageID = nil }
    }

    func deleteSelected() {
        guard let id = selectedPageID, let index = selectedIndex else { return }
        pages.remove(at: index)
        multiCropPageIDs.removeAll { $0 == id }
        if multiCropPageIDs.isEmpty && exportOptions.scope == .multiCrop { exportOptions.scope = .all }
        recognized = recognized.filter { $0.key.id != id }
        kindOverrides.removeValue(forKey: id)
        recognitionFailures = recognitionFailures.filter { $0.id != id }
        Task { await DocumentOCRCache.shared.remove([id]) }
        selectedPageID = pages.indices.contains(index) ? pages[index].id : pages.last?.id
        if pages.isEmpty || selectedPageID == id { selectedPageID = nil }
    }

    func deleteAll() {
        multiCropOriginal = nil
        multiCropPageIDs = []
        if exportOptions.scope == .multiCrop { exportOptions.scope = .all }
        let ids = Set(pages.map(\.id))
        pages.removeAll()
        recognized.removeAll()
        kindOverrides.removeAll()
        recognitionFailures.removeAll()
        Task { await DocumentOCRCache.shared.remove(ids) }
        selectedPageID = nil
    }

    func rotate(_ id: UUID, by turns: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].quarterTurns = ((pages[i].quarterTurns + turns) % 4 + 4) % 4
    }

    func rotateSelected(_ turns: Int) {
        if let id = selectedPageID { rotate(id, by: turns) }
    }

    func movePages(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    func movePage(_ id: UUID, by offset: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let target = i + offset
        guard pages.indices.contains(target) else { return }
        pages.swapAt(i, target)
    }

    func applyAdjustmentsToAll() {
        let adj = editingAdjustments
        for i in pages.indices { pages[i].adjustments = adj }
        defaultAdjustments = adj
    }

    func resetAdjustments() {
        var neutral = Adjustments.neutral
        neutral.threshold = 50
        editingAdjustments = neutral
    }

    // MARK: - Importazione

    func importFiles(_ urls: [URL]) {
        previewNamingActive = false
        busyMessage = localized("Importazione…")
        busyProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            var loaded: [ImageUtilities.LoadedImage] = []
            for (i, url) in urls.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                loaded += ImageUtilities.loadPages(from: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                let p = Double(i + 1) / Double(urls.count)
                await MainActor.run { self?.busyProgress = p }
            }
            let results = loaded
            await MainActor.run {
                guard let self else { return }
                for item in results {
                    let dpi = item.dpi ?? (max(item.image.width, item.image.height) > 2000 ? 300 : 150)
                    self.addPage(item.image, dpi: dpi, mode: .color, adjustments: Adjustments())
                }
                self.busyMessage = nil
                if results.isEmpty { self.alertMessage = localized("Nessuna immagine importabile nei file selezionati.") }
            }
        }
    }

    // MARK: - Salvataggio

    func save() {
        let targets: [ScannedPage]
        if exportOptions.scope == .selected {
            guard let page = selectedPage else {
                alertMessage = localized("Seleziona una pagina da salvare, oppure scegli “Tutte”.")
                return
            }
            targets = [page]
        } else if exportOptions.scope == .multiCrop {
            targets = multiCropPages
        } else {
            targets = pages
        }
        guard !targets.isEmpty else {
            alertMessage = localized("Non ci sono pagine da salvare.")
            return
        }

        let options = exportOptions
        let ext = options.format.fileExtension
        var name = FileNameBuilder.sanitize(fileName)
        if name.lowercased().hasSuffix("." + ext) { name = String(name.dropLast(ext.count + 1)) }
        if name.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            name = localizedFormat("Scansione %@", formatter.string(from: Date()))
        }

        let url: URL
        if let preset = selectedPreset {
            guard preset.folderExists else {
                alertMessage = localizedFormat("La cartella “%@” non esiste più. Modifica la destinazione “%@”.", preset.folderPath, preset.name)
                return
            }
            url = uniqueURL(in: preset.folderURL, name: name, ext: ext)
        } else {
            let panel = NSSavePanel()
            panel.title = localized("Salva scansione")
            panel.allowedContentTypes = [options.format.utType]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(name).\(ext)"
            if options.format.isSeparateDocument && targets.count > 1 {
                panel.message = localized("Verrà creato un file per ogni pagina (nome-001, nome-002, …).")
            }
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        busyMessage = targets.count == 1 ? localized("Salvataggio di una pagina…") : localizedFormat("Salvataggio di %lld pagine…", targets.count)
        busyProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let written = try await Exporter.export(pages: targets, options: options, to: url) { p in
                    Task { @MainActor in self?.busyProgress = p }
                }
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.fileNameEdited = false
                    NSWorkspace.shared.activateFileViewerSelecting(written)
                }
            } catch {
                await MainActor.run {
                    self?.busyMessage = nil
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }
}
