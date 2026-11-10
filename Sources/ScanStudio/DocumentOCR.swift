import Foundation
import CoreGraphics
import Vision

struct DocumentOCRResult {
    struct Line {
        let text: String
        let box: CGRect
    }
    let lines: [Line]
    let markdown: String
    var text: String { lines.map(\.text).joined(separator: "\n") }
}

enum DocumentOCRError: LocalizedError {
    case render, emptyResult
    var errorDescription: String? {
        switch self {
        case .render: return localized("Impossibile elaborare la pagina per il riconoscimento del testo.")
        case .emptyResult: return localized("Vision non ha restituito risultati per la pagina.")
        }
    }
}

/// Ogni variante di una pagina condivide una singola richiesta OCR, anche se ancora in corso.
actor DocumentOCRCache {
    static let shared = DocumentOCRCache()
    private struct Key: Hashable {
        let id: UUID
        let adjustments: Adjustments
        let mode: ColorMode
        let turns: Int
        init(_ page: ScannedPage) {
            id = page.id; adjustments = page.adjustments; mode = page.mode; turns = page.quarterTurns
        }
    }
    private var tasks: [Key: Task<DocumentOCRResult, Error>] = [:]

    func recognize(_ page: ScannedPage) async throws -> DocumentOCRResult {
        let key = Key(page)
        if let existing = tasks[key] { return try await existing.value }
        // Discard obsolete variants; active clients can still await their own task.
        tasks = tasks.filter { $0.key.id != page.id }
        let task = Task.detached(priority: .userInitiated) {
            guard let image = ImageProcessor.render(page.full, adjustments: page.adjustments,
                                                    mode: page.mode, quarterTurns: page.quarterTurns) else {
                throw DocumentOCRError.render
            }
            return try await DocumentOCR.recognize(image)
        }
        tasks[key] = task
        do { return try await task.value }
        catch { tasks.removeValue(forKey: key); throw error }
    }

    func remove(_ ids: Set<UUID>) { tasks = tasks.filter { !ids.contains($0.key.id) } }
}

enum DocumentOCR {
    static func recognize(_ image: CGImage) async throws -> DocumentOCRResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "it-IT"), Locale.Language(identifier: "en-US")]
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: image)
        guard let document = observations.first?.document else {
            // Una pagina senza testo resta esportabile come immagine o PDF.
            return DocumentOCRResult(lines: [], markdown: "")
        }
        var lines: [DocumentOCRResult.Line] = []
        for observation in document.text.lines {
            lines.append(DocumentOCRResult.Line(text: observation.transcript, box: observation.boundingBox.cgRect))
        }
        lines.sort { a, b in
            if a.box.maxY == b.box.maxY { return a.box.minX < b.box.minX }
            return a.box.maxY > b.box.maxY
        }
        return DocumentOCRResult(lines: lines, markdown: markdown(document))
    }

    private struct Block {
        let box: CGRect
        let text: String
    }
    private static func markdown(_ document: DocumentObservation.Container) -> String {
        var blocks: [Block] = []
        let tables = document.tables.map { $0.boundingRegion.boundingBox.cgRect }
        let lists = document.lists.map { $0.boundingRegion.boundingBox.cgRect }
        let embedded = tables + lists
        func belongsToStructure(_ box: CGRect) -> Bool {
            embedded.contains { region in
                let intersection = box.intersection(region)
                return !intersection.isNull && intersection.width * intersection.height > box.width * box.height * 0.5
            }
        }
        for paragraph in document.paragraphs {
            let box = paragraph.boundingRegion.boundingBox.cgRect
            guard !belongsToStructure(box) else { continue }
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let isTitle = paragraph.lines.contains { $0.isTitle }
                blocks.append(Block(box: box, text: (isTitle ? "# " : "") + text))
            }
        }
        for table in document.tables {
            let rows = table.rows.map { row in
                row.map { $0.content.text.transcript.replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: "<br>").trimmingCharacters(in: .whitespacesAndNewlines) }
            }.filter { !$0.isEmpty }
            guard let width = rows.map(\.count).max(), width > 0 else { continue }
            func row(_ values: [String]) -> String { "| " + (values + Array(repeating: "", count: max(0, width - values.count))).joined(separator: " | ") + " |" }
            var result = [row(rows[0]), row(Array(repeating: "---", count: width))]
            result += rows.dropFirst().map(row)
            blocks.append(Block(box: table.boundingRegion.boundingBox.cgRect, text: result.joined(separator: "\n")))
        }
        for list in document.lists {
            let items = list.items.map { "- " + $0.itemString.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0 != "- " }
            if !items.isEmpty { blocks.append(Block(box: list.boundingRegion.boundingBox.cgRect, text: items.joined(separator: "\n"))) }
        }
        blocks.sort { $0.box.maxY == $1.box.maxY ? $0.box.minX < $1.box.minX : $0.box.maxY > $1.box.maxY }
        if blocks.isEmpty { return document.text.transcript }
        return blocks.map(\.text).joined(separator: "\n\n")
    }
}
