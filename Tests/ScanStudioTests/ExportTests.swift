import XCTest
import AppKit
import PDFKit
@testable import ScanStudio

final class ExportTests: XCTestCase {
    func makePage() throws -> ScannedPage {
        let image = NSImage(size: NSSize(width: 1200, height: 1600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 1600).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 58), .foregroundColor: NSColor.black]
        ("FATTURA NUMERO 123" as NSString).draw(at: NSPoint(x: 100, y: 1350), withAttributes: attrs)
        ("ALFA ENERGIA SRL" as NSString).draw(at: NSPoint(x: 100, y: 1250), withAttributes: attrs)
        ("TOTALE EURO 42,00" as NSString).draw(at: NSPoint(x: 100, y: 1150), withAttributes: attrs)
        image.unlockFocus()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return ScannedPage(full: cg, preview: cg, thumbnail: cg, dpi: 150, mode: .color, adjustments: .neutral)
    }

    func testDefaultPDFIsMultipage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ExportOptions()
        XCTAssertEqual(options.format, .pdf)
        let destination = directory.appendingPathComponent("documento.pdf")
        let result = try await Exporter.export(pages: [try makePage(), try makePage()], options: options, to: destination) { _ in }
        XCTAssertEqual(result, [destination])
        XCTAssertEqual(PDFDocument(url: destination)?.pageCount, 2)
    }

    func testOptInMarkdownAndSearchablePDF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = try makePage()
        let pdf = dir.appendingPathComponent("scan.pdf")
        var options = ExportOptions()
        XCTAssertFalse(options.exportMarkdown)
        let first = try await Exporter.export(pages: [page], options: options, to: pdf) { _ in }
        XCTAssertEqual(first, [pdf])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("scan.md").path))
        let pdfText = try XCTUnwrap(PDFDocument(url: pdf)?.string)
        XCTAssertTrue(pdfText.localizedCaseInsensitiveContains("fattura"), pdfText)

        options.exportMarkdown = true
        let written = try await Exporter.export(pages: [page], options: options, to: pdf) { _ in }
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.last?.pathExtension, "md")
        let markdown = try String(contentsOf: try XCTUnwrap(written.last), encoding: .utf8)
        XCTAssertTrue(markdown.localizedCaseInsensitiveContains("fattura"), markdown)
        let oldMarkdown = try XCTUnwrap(written.last)
        let again = try await Exporter.export(pages: [page], options: options, to: pdf) { _ in }
        XCTAssertNotEqual(again.last, oldMarkdown)
        XCTAssertEqual(try String(contentsOf: oldMarkdown, encoding: .utf8), markdown)
    }
    func testMultipageImagesWithOneSeparateMarkdown() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page1 = try makePage()
        let page2 = try makePage()
        var options = ExportOptions()
        options.format = .png
        options.exportMarkdown = true
        let written = try await Exporter.export(pages: [page1, page2], options: options, to: dir.appendingPathComponent("scan.png")) { _ in }
        XCTAssertEqual(written.map(\.lastPathComponent), ["scan-001.png", "scan-002.png", "scan.md"])
        let markdown = try String(contentsOf: written[2], encoding: .utf8)
        XCTAssertTrue(markdown.contains(localizedFormat("Pagina %lld", 1)))
        XCTAssertTrue(markdown.contains(localizedFormat("Pagina %lld", 2)))
        XCTAssertTrue(markdown.localizedCaseInsensitiveContains("fattura"))
    }

    func testSeparateScansHaveOptionalSeparateMarkdown() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = ExportOptions()
        options.format = .pdfSingle
        options.exportMarkdown = true
        let written = try await Exporter.export(pages: [try makePage(), try makePage()], options: options, to: dir.appendingPathComponent("documento.pdf")) { _ in }
        XCTAssertEqual(written.map(\.lastPathComponent), ["documento-001.pdf", "documento-002.pdf", "documento-001.md", "documento-002.md"])
        XCTAssertTrue(try String(contentsOf: written[2], encoding: .utf8).localizedCaseInsensitiveContains("fattura"))
    }

}
