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
    private var persistenceSubscriptions: [AnyCancellable] = []
    private var recognized: [UUID: DocumentInfo] = [:]

    private static let presetsKey = "destinationPresets"
    private static let selectedPresetKey = "selectedDestinationPreset"

    let scanner = ScannerManager()
    private var modeForCurrentScan: ColorMode = .color

    init() {
        loadPersistedSettings()
        if let data = UserDefaults.standard.data(forKey: Self.presetsKey),
           let saved = try? JSONDecoder().decode([DestinationPreset].self, from: data) {
            presets = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedPresetKey),
           let id = UUID(uuidString: raw), presets.contains(where: { $0.id == id }) {
            selectedPresetID = id
        }
        scanner.onPageScanned = { [weak self] image, dpi in
            guard let self else { return }
            if self.settings.documentType == .idCard {
                self.handleIDCardScan(image, dpi: dpi)
                return
            }
            self.addPage(image, dpi: dpi, mode: self.modeForCurrentScan, adjustments: self.defaultAdjustments)
        }
        persistenceSubscriptions = startPersistingSettings()
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
        selectedPageID = nil
        scanner.requestOverview(settings: settings)
    }

    func scan() {
        modeForCurrentScan = settings.mode
        scanner.scan(settings: settings)
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
                    self.alertMessage = "Nessun documento riconosciuto nell'anteprima. Seleziona l'area manualmente."
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

    /// Pagina da cui ricavare il tipo di documento e l'attività
    var recognitionPage: ScannedPage? {
        exportOptions.scope == .selected ? selectedPage : pages.first
    }

    /// Modifica manuale del nome: da qui in poi il suggerimento non lo sovrascrive più
    func setFileName(_ name: String) {
        fileName = name
        fileNameEdited = !name.isEmpty
        if name.isEmpty { refreshFileName() }
    }

    func restoreSuggestedFileName() {
        fileNameEdited = false
        refreshFileName()
    }

    func analyzeCurrentPage() {
        guard let page = recognitionPage else {
            if !fileNameEdited { fileName = "" }
            return
        }
        if recognized[page.id] != nil || settings.documentType == .idCard {
            refreshFileName()
            return
        }
        let id = page.id, image = page.preview
        Task.detached(priority: .utility) { [weak self] in
            let info = DocumentRecognizer.analyze(image)
            await MainActor.run {
                guard let self else { return }
                self.recognized[id] = info
                if self.recognitionPage?.id == id { self.refreshFileName() }
            }
        }
    }

    func refreshFileName() {
        guard !fileNameEdited else { return }
        guard let page = recognitionPage else { fileName = ""; return }
        var info = recognized[page.id] ?? DocumentInfo()
        if settings.documentType == .idCard { info = DocumentInfo(kind: .idCard, business: nil) }
        fileName = FileNameBuilder.build(pattern: selectedPreset?.fileNamePattern ?? DestinationPreset.defaultPattern,
                                         kind: info.kind.fileLabel, business: info.business)
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
        busyMessage = "Composizione del documento…"
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
                    self.alertMessage = "Impossibile comporre la pagina del documento."
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
        if let id = selectedPageID, ids.contains(id) { selectedPageID = nil }
    }

    func deleteSelected() {
        guard let id = selectedPageID, let index = selectedIndex else { return }
        pages.remove(at: index)
        selectedPageID = pages.indices.contains(index) ? pages[index].id : pages.last?.id
        if pages.isEmpty || selectedPageID == id { selectedPageID = nil }
    }

    func deleteAll() {
        pages.removeAll()
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
        busyMessage = "Importazione…"
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
                if results.isEmpty { self.alertMessage = "Nessuna immagine importabile nei file selezionati." }
            }
        }
    }

    // MARK: - Salvataggio

    func save() {
        let targets: [ScannedPage]
        if exportOptions.scope == .selected {
            guard let page = selectedPage else {
                alertMessage = "Seleziona una pagina da salvare, oppure scegli “Tutte”."
                return
            }
            targets = [page]
        } else {
            targets = pages
        }
        guard !targets.isEmpty else {
            alertMessage = "Non ci sono pagine da salvare."
            return
        }

        let options = exportOptions
        let ext = options.format.fileExtension
        var name = FileNameBuilder.sanitize(fileName)
        if name.lowercased().hasSuffix("." + ext) { name = String(name.dropLast(ext.count + 1)) }
        if name.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            name = "Scansione \(formatter.string(from: Date()))"
        }

        let url: URL
        if let preset = selectedPreset {
            guard preset.folderExists else {
                alertMessage = "La cartella “\(preset.folderPath)” non esiste più. Modifica la destinazione “\(preset.name)”."
                return
            }
            url = uniqueURL(in: preset.folderURL, name: name, ext: ext)
        } else {
            let panel = NSSavePanel()
            panel.title = "Salva scansione"
            panel.allowedContentTypes = [options.format.utType]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(name).\(ext)"
            if !options.format.isMultiPage && targets.count > 1 {
                panel.message = "Verrà creato un file per ogni pagina (nome-001, nome-002, …)."
            }
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        busyMessage = "Salvataggio di \(targets.count) \(targets.count == 1 ? "pagina" : "pagine")…"
        busyProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let written = try Exporter.export(pages: targets, options: options, to: url) { p in
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
