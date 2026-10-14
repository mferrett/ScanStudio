import Foundation
import AppKit
import Combine
import ImageCaptureCore

/// Impostazioni dell'utente salvate in UserDefaults e ripristinate all'avvio successivo.
/// (Destinazioni e preset sono gestiti a parte da AppModel.)
struct PersistedSettings: Codable {
    var documentType: String
    var idAutoCrop: Bool
    var source: UInt
    var mode: ColorMode
    var resolution: Int
    var feederSize: String
    var duplex: Bool
    var adjustments: Adjustments
    var exportFormat: String
    var jpegQuality: Double
    var pdfUseJPEG: Bool
    var ocr: Bool
    var exportScope: String
}

extension AppModel {
    private static let persistedSettingsKey = "persistedSettings"

    func loadPersistedSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSettingsKey),
              let saved = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }
        settings.documentType = DocumentType(rawValue: saved.documentType) ?? .standard
        settings.idAutoCrop = saved.idAutoCrop
        settings.source = ICScannerFunctionalUnitType(rawValue: saved.source) ?? .flatbed
        settings.mode = saved.mode
        settings.resolution = saved.resolution
        settings.feederSize = FeederPageSize(rawValue: saved.feederSize) ?? .a4
        settings.duplex = saved.duplex
        defaultAdjustments = saved.adjustments
        exportOptions.format = ExportFormat(rawValue: saved.exportFormat) ?? .pdf
        exportOptions.jpegQuality = saved.jpegQuality
        exportOptions.pdfUseJPEG = saved.pdfUseJPEG
        exportOptions.ocr = saved.ocr
        exportOptions.scope = ExportScope(rawValue: saved.exportScope) ?? .all
    }

    func savePersistedSettings() {
        let snapshot = PersistedSettings(
            documentType: settings.documentType.rawValue,
            idAutoCrop: settings.idAutoCrop,
            source: settings.source.rawValue,
            mode: settings.mode,
            resolution: settings.resolution,
            feederSize: settings.feederSize.rawValue,
            duplex: settings.duplex,
            adjustments: defaultAdjustments,
            exportFormat: exportOptions.format.rawValue,
            jpegQuality: exportOptions.jpegQuality,
            pdfUseJPEG: exportOptions.pdfUseJPEG,
            ocr: exportOptions.ocr,
            exportScope: exportOptions.scope.rawValue)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.persistedSettingsKey)
        }
    }

    /// Salva dopo ogni modifica (con un breve ritardo) e all'uscita: chiudere l'app da Xcode
    /// non invia la notifica di terminazione, quindi il solo salvataggio finale non basterebbe.
    func startPersistingSettings() -> [AnyCancellable] {
        let onChange = objectWillChange
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.savePersistedSettings() }
        let onQuit = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.savePersistedSettings() }
        return [onChange, onQuit]
    }
}
