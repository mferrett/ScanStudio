import Foundation
import CoreGraphics
import ImageCaptureCore
import UniformTypeIdentifiers

// MARK: - Modalità colore

enum ColorMode: String, CaseIterable, Identifiable, Codable {
    case color, grayscale, blackWhite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: return "Colore"
        case .grayscale: return "Grigi"
        case .blackWhite: return "B/N"
        }
    }

    var longLabel: String {
        switch self {
        case .color: return "Colore"
        case .grayscale: return "Scala di grigi"
        case .blackWhite: return "Bianco e nero"
        }
    }
}

// MARK: - Sorgente scanner

extension ICScannerFunctionalUnitType {
    var label: String {
        switch self {
        case .flatbed: return "Piano"
        case .documentFeeder: return "Alimentatore (ADF)"
        case .positiveTransparency: return "Diapositive"
        case .negativeTransparency: return "Negativi"
        @unknown default: return "Altro"
        }
    }
}

// MARK: - Formato pagina per l'alimentatore

enum FeederPageSize: String, CaseIterable, Identifiable {
    case a4, a5, letter, legal, maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "Lettera US"
        case .legal: return "Legal US"
        case .maximum: return "Massimo"
        }
    }

    /// Dimensioni in pollici (nil = area massima dello scanner)
    var inches: CGSize? {
        switch self {
        case .a4: return CGSize(width: 8.27, height: 11.69)
        case .a5: return CGSize(width: 5.83, height: 8.27)
        case .letter: return CGSize(width: 8.5, height: 11)
        case .legal: return CGSize(width: 8.5, height: 14)
        case .maximum: return nil
        }
    }
}

// MARK: - Tipo di documento

enum DocumentType: String, CaseIterable, Identifiable {
    case standard, idCard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Scansione classica"
        case .idCard: return "Documento di identità"
        }
    }
}

// MARK: - Impostazioni di scansione

struct ScanSettings {
    var documentType: DocumentType = .standard
    /// Documento di identità: ritaglia ogni lato prima di comporre la pagina
    var idAutoCrop = true
    var source: ICScannerFunctionalUnitType = .flatbed
    var mode: ColorMode = .color
    var resolution: Int = 300
    /// Area selezionata, normalizzata 0…1 con origine in alto a sinistra
    var selection = CGRect(x: 0, y: 0, width: 1, height: 1)
    var feederSize: FeederPageSize = .a4
    var duplex = false
}

// MARK: - Regolazioni immagine

struct Adjustments: Hashable, Codable {
    var brightness: Double = 0      // Luminosità  -100…100
    var contrast: Double = 0        // Contrasto   -100…100
    var exposure: Double = 0        // Brillantezza (esposizione) -100…100
    var gamma: Double = 0           // Toni medi   -100…100
    var saturation: Double = 0      // Saturazione -100…100
    var sharpness: Double = 0       // Nitidezza   0…100
    var noiseReduction: Double = 0  // Riduzione rumore 0…100
    var threshold: Double = 50      // Soglia B/N  0…100
    var autoEnhance = false
    var invert = false

    static let neutral = Adjustments()
}

// MARK: - Pagina acquisita

struct ScannedPage: Identifiable {
    let id = UUID()
    let full: CGImage        // immagine a piena risoluzione
    let preview: CGImage     // versione ridotta per l'anteprima
    let thumbnail: CGImage   // miniatura per l'elenco pagine
    let dpi: Double
    var mode: ColorMode
    var adjustments: Adjustments
    var quarterTurns = 0     // rotazione in quarti di giro (orari)

    var sizeDescription: String {
        let w = Double(full.width) / dpi * 2.54
        let h = Double(full.height) / dpi * 2.54
        let fmt = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        return "\(w.formatted(fmt)) × \(h.formatted(fmt)) cm"
    }
}

// MARK: - Esportazione

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, png, jpeg, tiff

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: return "PDF (multipagina)"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF (multipagina)"
        }
    }

    var utType: UTType {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }

    /// I formati che non supportano più pagine salvano un file per pagina
    var isMultiPage: Bool { self == .pdf || self == .tiff }
}

enum ExportScope: String, CaseIterable, Identifiable {
    case all, selected
    var id: String { rawValue }
    var label: String { self == .all ? "Tutte" : "Solo selezionata" }
}

struct ExportOptions {
    var format: ExportFormat = .pdf
    var jpegQuality: Double = 0.85
    var pdfUseJPEG = true
    var ocr = true
    var scope: ExportScope = .all
}
