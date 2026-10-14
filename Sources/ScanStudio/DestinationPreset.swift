import Foundation

/// Cartella di destinazione pre-configurata con il relativo modello di nome file.
struct DestinationPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var folderPath: String
    /// Segnaposto: {tipo} {attività} {data}
    var fileNamePattern: String = DestinationPreset.defaultPattern

    static let defaultPattern = "{tipo} {attività} - {data}"

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    var folderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir) && isDir.boolValue
    }
}

enum FileNameBuilder {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "ddMMyyyy"
        return f
    }()

    static func build(pattern: String, kind: String, business: String?, date: Date = Date()) -> String {
        var s = pattern
            .replacingOccurrences(of: "{tipo}", with: kind)
            .replacingOccurrences(of: "{attività}", with: business ?? "")
            .replacingOccurrences(of: "{data}", with: dateFormatter.string(from: date))
        // Se l'attività manca, evita doppi spazi e separatori orfani
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return sanitize(s)
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters)
        return name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}
