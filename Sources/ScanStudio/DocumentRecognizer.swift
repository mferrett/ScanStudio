import Foundation
import CoreGraphics
import Vision
import NaturalLanguage

/// Tipo di documento riconosciuto dal testo (OCR Vision).
enum DocumentKind {
    case receipt, invoice, idCard, passport, driverLicense, healthCard, unknown

    /// Parola usata nel nome del file
    var fileLabel: String {
        switch self {
        case .receipt: return "ricevuta"
        case .invoice: return "fattura"
        case .idCard: return "documento identità"
        case .passport: return "passaporto"
        case .driverLicense: return "patente"
        case .healthCard: return "tessera sanitaria"
        case .unknown: return "documento"
        }
    }
}

struct DocumentInfo {
    var kind: DocumentKind = .unknown
    /// Esercente / attività emittente (nil se non riconosciuta)
    var business: String?
}

/// Riconoscimento del tipo di documento e dell'attività emittente.
/// Usa Vision (OCR con posizione e altezza del testo) e NaturalLanguage (nomi di organizzazioni).
enum DocumentRecognizer {

    static func analyze(_ image: CGImage) -> DocumentInfo {
        let lines = recognizeLines(in: image)
        guard !lines.isEmpty else { return DocumentInfo() }
        let text = lines.map(\.text).joined(separator: "\n")
        let kind = classify(text.lowercased())
        let business: String? = (kind == .receipt || kind == .invoice) ? findBusiness(in: lines, fullText: text) : nil
        return DocumentInfo(kind: kind, business: business)
    }

    // MARK: - OCR

    private struct Line {
        let text: String
        let top: CGFloat      // 0 = bordo superiore, 1 = inferiore
        let height: CGFloat   // altezza relativa del testo
    }

    private static func recognizeLines(in image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        return results.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty else { return nil }
            return Line(text: text, top: 1 - obs.boundingBox.maxY, height: obs.boundingBox.height)
        }
        .sorted { $0.top < $1.top }
    }

    // MARK: - Tipo di documento

    private static func classify(_ t: String) -> DocumentKind {
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["passaporto", "passport"]) { return .passport }
        if has(["patente di guida", "driving licence", "driving license"]) { return .driverLicense }
        if has(["tessera sanitaria", "team tessera europea"]) { return .healthCard }
        if has(["carta d'identità", "carta d’identità", "carta di identità", "carta d'identita", "identity card"]) { return .idCard }
        if has(["fattura", "invoice"]) && !has(["fattura non richiesta"]) { return .invoice }
        if has(["ricevuta", "scontrino", "documento commerciale", "receipt", "totale", "importo pagato", "pagamento elettronico"]) {
            return .receipt
        }
        return .unknown
    }

    // MARK: - Attività emittente

    private static let legalSuffix = try! NSRegularExpression(
        pattern: #"\b(s\.?r\.?l\.?s?|s\.?p\.?a\.?|s\.?n\.?c\.?|s\.?a\.?s\.?|s\.?c\.?a\.?r\.?l\.?|ltd|gmbh|inc|llc)\b"#,
        options: .caseInsensitive)

    private static let noiseWords = ["p.iva", "p. iva", "partita iva", "c.f.", "cod. fisc", "codice fiscale", "tel", "fax",
                                     "www.", "http", "@", "via ", "viale ", "piazza ", "corso ", "scontrino", "ricevuta",
                                     "fattura", "documento", "totale", "cassa", "data", "ora ", "arrivederci", "grazie",
                                     "benvenuti", "cliente", "n.", "nr", "euro", "€"]

    private static func findBusiness(in lines: [Line], fullText: String) -> String? {
        // L'intestazione sta nella parte alta della pagina
        let header = lines.filter { $0.top < 0.4 }
        let candidates = header.filter { isPlausibleName($0.text) }
        guard !candidates.isEmpty else { return organizationByNL(fullText).map(clean) }

        let maxHeight = candidates.map(\.height).max() ?? 1
        func score(_ l: Line) -> Double {
            var s = Double(l.height / maxHeight) * 2          // testo più grande = insegna
            s += Double(1 - l.top)                            // più in alto è meglio
            let range = NSRange(l.text.startIndex..., in: l.text)
            if legalSuffix.firstMatch(in: l.text, range: range) != nil { s += 1.5 }
            if l.text == l.text.uppercased() { s += 0.3 }
            if organizationByNL(l.text) != nil { s += 1 }
            return s
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }
        return clean(best.text)
    }

    private static func isPlausibleName(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard s.count >= 3, s.count <= 50 else { return false }
        if noiseWords.contains(where: { lower.contains($0) }) { return false }
        let letters = s.filter(\.isLetter).count
        return Double(letters) / Double(s.count) > 0.6
    }

    private static func organizationByNL(_ text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: String?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .organizationName { found = String(text[range]); return false }
            return true
        }
        return found
    }

    /// Toglie suffissi societari e rende leggibile un testo tutto maiuscolo.
    private static func clean(_ raw: String) -> String {
        var s = raw
        let range = NSRange(s.startIndex..., in: s)
        s = legalSuffix.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–,.*"))
        if s == s.uppercased() { s = s.capitalized }
        return s.isEmpty ? raw : s
    }
}
