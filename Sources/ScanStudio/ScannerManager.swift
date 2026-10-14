import Foundation
import AppKit
import ImageCaptureCore
import UniformTypeIdentifiers
import CoreGraphics

/// Gestisce la scoperta degli scanner e la comunicazione tramite ImageCaptureCore
/// (lo stesso framework usato da Acquisizione Immagini e Anteprima).
/// I callback di ImageCaptureCore arrivano sul main thread.
final class ScannerManager: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle, opening, configuring, ready, overview, scanning
    }

    /// Se l'area selezionata risultasse capovolta verticalmente con un certo
    /// modello di scanner, impostare a false.
    static let scanAreaOriginIsTopLeft = true

    @Published private(set) var scanners: [ICScannerDevice] = []
    @Published private(set) var selectedScanner: ICScannerDevice?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var availableSources: [ICScannerFunctionalUnitType] = []
    @Published private(set) var activeSource: ICScannerFunctionalUnitType?
    @Published private(set) var resolutions: [Int] = []
    /// Dimensioni fisiche dell'area di scansione, in pollici
    @Published private(set) var physicalSize = CGSize(width: 8.5, height: 11.69)
    @Published private(set) var overviewImage: CGImage?
    @Published private(set) var supportsDuplex = false
    @Published private(set) var documentLoaded: Bool?
    @Published private(set) var pagesInCurrentJob = 0
    @Published var errorMessage: String?

    /// Chiamato per ogni pagina ricevuta (immagine, dpi)
    var onPageScanned: ((CGImage, Double) -> Void)?

    var isBusy: Bool { phase == .overview || phase == .scanning }
    var isReady: Bool { phase == .ready }

    private let browser = ICDeviceBrowser()
    private let downloadDirectory: URL
    private var pendingAction: (() -> Void)?
    private var lastResolution = 300
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var openAttempt = 0
    private var activationObserver: NSObjectProtocol?

    override init() {
        downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanStudio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        super.init()

        browser.delegate = self
        let rawMask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.bluetooth.rawValue
        let mask: ICDeviceTypeMask? = ICDeviceTypeMask(rawValue: rawMask)
        browser.browsedDeviceTypeMask = mask ?? .scanner
        browser.start()

        // Al ritorno in primo piano riprova la connessione (scanner acceso nel frattempo)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Non riavviare mai la ricerca qui: all'avvio l'app diventa attiva mentre lo scanner
            // viene ancora scoperto, e il riavvio del browser fa comparire/sparire il dispositivo in loop.
            guard let self, !self.isBusy, self.selectedScanner != nil, self.phase == .idle else { return }
            self.reconnect()
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        retryWork?.cancel()
        browser.stop()
        try? FileManager.default.removeItem(at: downloadDirectory)
    }

    // MARK: - Selezione dispositivo

    func select(_ scanner: ICScannerDevice?) {
        if let current = selectedScanner, current !== scanner, current.hasOpenSession {
            current.requestCloseSession()
        }
        selectedScanner = scanner
        overviewImage = nil
        availableSources = []
        activeSource = nil
        resolutions = []
        pendingAction = nil

        retryWork?.cancel()
        retryCount = 0
        guard let scanner else { phase = .idle; return }
        scanner.delegate = self
        phase = .idle
        reconnect()
    }

    // MARK: - Riconnessione

    /// Riapre la sessione con lo scanner selezionato (o riavvia la ricerca se non ce n'è).
    func reconnect() {
        retryWork?.cancel()
        guard let scanner = selectedScanner else {
            if let first = scanners.first { select(first) } else { rediscover() }
            return
        }
        guard phase == .idle else { return }
        phase = .opening
        if scanner.hasOpenSession {
            sessionOpened(scanner)
            return
        }
        openAttempt += 1
        let attempt = openAttempt
        scanner.requestOpenSession()
        // Se lo scanner non risponde, riprova (ignora i timeout di tentativi precedenti)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.openAttempt == attempt, self.selectedScanner === scanner,
                  self.phase == .opening else { return }
            self.phase = .idle
            self.scheduleReconnect()
        }
    }

    /// Riavvia la ricerca dei dispositivi
    func rediscover() {
        browser.stop()
        browser.start()
    }

    private func scheduleReconnect() {
        guard selectedScanner != nil else { return }
        retryWork?.cancel()
        let delay = min(3.0 * Double(retryCount + 1), 30)
        retryCount += 1
        let work = DispatchWorkItem { [weak self] in self?.reconnect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func displayName(of scanner: ICScannerDevice) -> String {
        let name: String? = scanner.name
        return name ?? "Scanner"
    }

    private func sessionOpened(_ scanner: ICScannerDevice) {
        let types: [ICScannerFunctionalUnitType] = scanner.availableFunctionalUnitTypes.compactMap {
            let t: ICScannerFunctionalUnitType? = ICScannerFunctionalUnitType(rawValue: $0.uintValue)
            return t
        }
        availableSources = types

        // Il framework seleziona da solo un'unità subito dopo l'apertura della sessione:
        // se non è ancora pronta, si attende scannerDevice(_:didSelect:error:) senza forzare la selezione
        // (richiedere un'unità non ancora istanziata dà l'errore -9922, parametro non valido).
        let current: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        guard let current else {
            phase = .configuring
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.selectedScanner === scanner, self.phase == .configuring else { return }
                let unit: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
                if let unit { self.refresh(from: unit); self.phase = .ready }
                else { self.phase = .idle; self.scheduleReconnect() }
            }
            return
        }
        refresh(from: current)
        phase = .ready
        // Preferisce il piano di scansione se disponibile
        let preferred: ICScannerFunctionalUnitType = types.contains(.flatbed) ? .flatbed : (types.first ?? current.type)
        if current.type != preferred, types.contains(preferred) {
            phase = .configuring
            scanner.requestSelect(preferred)
        }
    }

    /// Cambia sorgente (piano, ADF, diapositive…)
    func switchSource(_ type: ICScannerFunctionalUnitType) {
        guard let scanner = selectedScanner, scanner.hasOpenSession, !isBusy,
              availableSources.contains(type) else { return }
        let current: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        if current?.type == type { return }
        overviewImage = nil
        phase = .configuring
        scanner.requestSelect(type)
    }

    // MARK: - Anteprima e scansione

    func requestOverview(settings: ScanSettings) {
        withUnit(settings.source) { [weak self] scanner, unit in
            guard let self else { return }
            guard unit.type != .documentFeeder else {
                self.errorMessage = "L'anteprima non è disponibile con l'alimentatore automatico."
                return
            }
            self.configure(unit, settings: settings, forOverview: true)
            self.phase = .overview
            scanner.requestOverviewScan()
        }
    }

    func scan(settings: ScanSettings) {
        withUnit(settings.source) { [weak self] scanner, unit in
            guard let self else { return }
            self.configure(unit, settings: settings, forOverview: false)

            scanner.transferMode = .fileBased
            scanner.downloadsDirectory = self.downloadDirectory
            scanner.documentName = "scan-\(Int(Date().timeIntervalSince1970))"
            scanner.documentUTI = UTType.tiff.identifier

            self.pagesInCurrentJob = 0
            self.phase = .scanning
            scanner.requestScan()
        }
    }

    func cancel() {
        guard let scanner = selectedScanner, isBusy else { return }
        scanner.cancelScan()
    }

    // MARK: - Configurazione unità

    private func withUnit(_ type: ICScannerFunctionalUnitType,
                          _ action: @escaping (ICScannerDevice, ICScannerFunctionalUnit) -> Void) {
        guard let scanner = selectedScanner, scanner.hasOpenSession, !isBusy else {
            errorMessage = "Lo scanner non è pronto."
            return
        }
        let current: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        if let current, current.type == type {
            action(scanner, current)
            return
        }
        pendingAction = { [weak self] in
            guard let self, let s = self.selectedScanner else { return }
            let unit: ICScannerFunctionalUnit? = s.selectedFunctionalUnit
            guard let unit else { return }
            action(s, unit)
        }
        phase = .configuring
        scanner.requestSelect(type)
    }

    private func configure(_ unit: ICScannerFunctionalUnit, settings: ScanSettings, forOverview: Bool) {
        if unit.supportedMeasurementUnits.contains(Int(ICScannerMeasurementUnit.inches.rawValue)) {
            unit.measurementUnit = .inches
        }
        unit.pixelDataType = settings.mode == .color ? .RGB : .gray
        if unit.supportedBitDepths.contains(8) {
            unit.bitDepth = .depth8Bits
        }

        let resolution = nearestResolution(to: settings.resolution, in: unit)
        lastResolution = resolution
        if !forOverview {
            unit.resolution = resolution
        }

        let factor = unitsPerInch(unit)
        let phys = physicalSize

        if forOverview {
            unit.scanArea = CGRect(x: 0, y: 0, width: phys.width * factor, height: phys.height * factor)
            return
        }

        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            let page = settings.feederSize.inches ?? phys
            let w = phys.width > 0 ? min(page.width, phys.width) : page.width
            let h = phys.height > 0 ? min(page.height, phys.height) : page.height
            unit.scanArea = CGRect(x: 0, y: 0, width: w * factor, height: h * factor)
            if feeder.supportsDuplexScanning {
                feeder.duplexScanningEnabled = settings.duplex
            }
        } else {
            let sel = settings.selection.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let y = Self.scanAreaOriginIsTopLeft ? sel.minY : (1 - sel.maxY)
            unit.scanArea = CGRect(x: sel.minX * phys.width * factor,
                                   y: y * phys.height * factor,
                                   width: sel.width * phys.width * factor,
                                   height: sel.height * phys.height * factor)
        }
    }

    private func unitsPerInch(_ unit: ICScannerFunctionalUnit) -> CGFloat {
        switch unit.measurementUnit {
        case .inches: return 1
        case .centimeters: return 2.54
        case .picas: return 6
        case .points: return 72
        case .twips: return 1440
        case .pixels: return CGFloat(max(unit.resolution, 1))
        @unknown default: return 1
        }
    }

    private func nearestResolution(to target: Int, in unit: ICScannerFunctionalUnit) -> Int {
        let supported = unit.supportedResolutions
        if supported.isEmpty { return target }
        return supported.min(by: { abs($0 - target) < abs($1 - target) }) ?? target
    }

    private func refresh(from unit: ICScannerFunctionalUnit) {
        if unit.supportedMeasurementUnits.contains(Int(ICScannerMeasurementUnit.inches.rawValue)) {
            unit.measurementUnit = .inches
        }
        let factor = unitsPerInch(unit)
        let phys = unit.physicalSize
        if phys.width > 0, phys.height > 0 {
            physicalSize = CGSize(width: phys.width / factor, height: phys.height / factor)
        } else {
            physicalSize = CGSize(width: 8.5, height: 11.69)
        }
        activeSource = unit.type

        // Risoluzioni: preferite dal driver, oppure un elenco di valori comuni supportati
        let supported = unit.supportedResolutions
        let preferred = unit.preferredResolutions
        var list = Array(preferred.isEmpty ? supported : preferred)
        if list.count > 12 || list.isEmpty {
            let common = [75, 100, 150, 200, 240, 300, 400, 600, 1200, 2400, 4800]
            let filtered = common.filter { supported.contains($0) }
            list = filtered.isEmpty ? (list.isEmpty ? [150, 300, 600] : Array(list.prefix(12))) : filtered
        }
        resolutions = list.sorted()

        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            supportsDuplex = feeder.supportsDuplexScanning
            documentLoaded = feeder.documentLoaded
        } else {
            supportsDuplex = false
            documentLoaded = nil
        }
        let overview: CGImage? = unit.overviewImage
        overviewImage = overview
    }

    private func report(_ error: Error?, context: String) {
        guard let error else { return }
        let ns = error as NSError
        // Annullamento da parte dell'utente: nessun messaggio
        if ns.code == -9923 || ns.localizedDescription.lowercased().contains("cancel") { return }
        errorMessage = "\(context): \(ns.localizedDescription) (codice \(ns.code))"
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ScannerManager: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        if !scanners.contains(where: { $0 === scanner }) {
            scanners.append(scanner)
        }
        if selectedScanner == nil {
            select(scanners.first)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        scanners.removeAll { $0 === device }
        if selectedScanner === device {
            select(scanners.first)
        }
    }
}

// MARK: - ICScannerDeviceDelegate

extension ScannerManager: ICScannerDeviceDelegate {
    func didRemove(_ device: ICDevice) {
        scanners.removeAll { $0 === device }
        if selectedScanner === device {
            select(scanners.first)
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard device === selectedScanner, let scanner = device as? ICScannerDevice else { return }
        if let error {
            phase = .idle
            // Segnala l'errore solo al primo tentativo, poi riprova in silenzio
            if retryCount == 0 { report(error, context: "Impossibile aprire la sessione con lo scanner") }
            scheduleReconnect()
            return
        }
        retryCount = 0
        sessionOpened(scanner)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard device === selectedScanner else { return }
        phase = .idle
        pendingAction = nil
        // Chiusura inattesa (scanner spento o in standby): riprova a connettersi
        if scanners.contains(where: { $0 === device }) { scheduleReconnect() }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        guard device === selectedScanner, phase == .idle else { return }
        reconnect()
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        report(error, context: "Errore dello scanner")
    }

    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        guard scanner === selectedScanner else { return }
        if scanner.hasOpenSession { sessionOpened(scanner) } else if phase == .idle { reconnect() }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        guard scanner === selectedScanner else { return }
        if let error {
            pendingAction = nil
            // Se il driver ha comunque un'unità attiva, si usa quella senza disturbare l'utente
            let active: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
            if let active {
                refresh(from: active)
                phase = .ready
                if (error as NSError).code == -9922 /* parametro non valido */ { return }
            } else {
                phase = .idle
            }
            report(error, context: "Impossibile selezionare la sorgente")
            return
        }
        refresh(from: functionalUnit)
        phase = .ready
        if let action = pendingAction {
            pendingAction = nil
            action()
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let loaded = ImageUtilities.load(data: data) else {
            errorMessage = "Impossibile leggere l'immagine ricevuta dallo scanner."
            return
        }
        pagesInCurrentJob += 1
        onPageScanned?(loaded.image, loaded.dpi ?? Double(lastResolution))
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
        phase = .ready
        if let error {
            report(error, context: "Anteprima non riuscita")
            return
        }
        let unit: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        let overview: CGImage? = unit?.overviewImage
        overviewImage = overview
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        phase = .ready
        let unit: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            documentLoaded = feeder.documentLoaded
        }
        report(error, context: "Scansione non riuscita")
    }
}
