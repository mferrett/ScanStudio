import XCTest
import AppKit
@testable import ScanStudio

@MainActor
final class PreviewNamingTests: XCTestCase {
    private func page() throws -> ScannedPage {
        let image = NSImage(size: NSSize(width: 1200, height: 1600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 1600).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 70), .foregroundColor: NSColor.black]
        ("FATTURA NUMERO 123" as NSString).draw(at: NSPoint(x: 100, y: 1300), withAttributes: attrs)
        ("PARTITA IVA 12345678" as NSString).draw(at: NSPoint(x: 100, y: 1200), withAttributes: attrs)
        image.unlockFocus()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return ScannedPage(full: cg, preview: cg, thumbnail: cg, dpi: 150, mode: .color, adjustments: .neutral)
    }
    private func waitForOverview(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if model.previewInfo != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Analisi anteprima non completata")
    }
    func testNewPreviewReplacesPreviousName() async throws {
        let model = AppModel(scanner: ScannerManager(discoverDevices: false), persistSettings: false)
        let sample = try page()
        model.pages = [sample]
        model.setFileName("Nome scansione precedente")
        model.preview()
        model.analyzeOverview(sample.full)
        try await waitForOverview(model)
        XCTAssertTrue(model.fileName.contains(localized("fattura")))
        model.selectedKindOverride = .receipt
        XCTAssertTrue(model.fileName.contains(localized("ricevuta")))
    }
    func testUserEditDuringNewPreviewIsPreserved() async throws {
        let model = AppModel(scanner: ScannerManager(discoverDevices: false), persistSettings: false)
        let sample = try page()
        model.setFileName("Nome precedente")
        model.preview()
        model.analyzeOverview(sample.full)
        model.setFileName("Nome scelto durante anteprima")
        try await waitForOverview(model)
        XCTAssertEqual(model.fileName, "Nome scelto durante anteprima")
    }
    func testLatePreviewDoesNotOverrideSelectedPage() async throws {
        let model = AppModel(scanner: ScannerManager(discoverDevices: false), persistSettings: false)
        let sample = try page()
        model.pages = [sample]
        model.preview()
        model.analyzeOverview(sample.full)
        model.selectPageForViewing(sample.id)
        model.setFileName("Nome della pagina selezionata")
        try await waitForOverview(model)
        XCTAssertEqual(model.fileName, "Nome della pagina selezionata")
    }
}
