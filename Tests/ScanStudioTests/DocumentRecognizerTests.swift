import XCTest
import AppKit
@testable import ScanStudio

final class DocumentRecognizerTests: XCTestCase {
    func testDocumentTypesAndSpecificity() {
        let examples: [(String, DocumentKind)] = [
            ("ALFA ENERGIA SRL\nFATTURA NUMERO 123\nPartita IVA 012345", .invoice),
            ("CERTIFICATO MEDICO\nSi certifica che il paziente...", .medicalCertificate),
            ("REFERTO DI LABORATORIO\nPaziente\nEsame", .medicalReport),
            ("ESTRATTO CONTO\nSaldo iniziale\nSaldo finale", .bankStatement),
            ("BOLLETTA ENERGIA ELETTRICA\nConsumi fornitura", .bill),
            ("CONTRATTO DI LOCAZIONE\nLe parti sottoscrivono", .contract),
            ("PREVENTIVO\nValidità offerta", .estimate),
            ("CEDOLINO PAGA\nRetribuzione dipendente", .payslip),
            ("Carta d’identità\nComune di esempio", .idCard),
            ("DOCUMENTO COMMERCIALE\nPagamento elettronico", .receipt),
            ("CERTIFICATO DI RESIDENZA\nSi certifica", .certificate)
        ]
        for (text, expected) in examples {
            XCTAssertEqual(DocumentRecognizer.classify(text), expected, text)
        }
    }

    func testIncidentalAndNegatedWordsDoNotAssignType() {
        XCTAssertEqual(DocumentRecognizer.classify("Avviso\nComunicazione generale\nSi fa riferimento alla fattura non richiesta."), .unknown)
        XCTAssertEqual(DocumentRecognizer.classify("Relazione\nDiscussione\nIl totale è indicativo."), .unknown)
        XCTAssertEqual(DocumentRecognizer.classify("Informazioni\nAltro\nIl contratto verrà discusso in seguito."), .unknown)
        XCTAssertEqual(DocumentRecognizer.classify("Passaporti e documentazione generica"), .unknown)
    }

    func testImmediateResultIsAvailableBeforeRefinement() async {
        let result = DocumentOCRResult(lines: [
            .init(text: "FATTURA 123", box: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.05)),
            .init(text: "Partita IVA 012345", box: CGRect(x: 0.1, y: 0.75, width: 0.5, height: 0.05))
        ], markdown: "")
        let quick = DocumentRecognizer.analyzeQuick(result)
        XCTAssertEqual(quick.kind, .invoice)
        let refined = await DocumentRecognizer.refine(result, initial: quick)
        XCTAssertEqual(refined.kind, .invoice)
    }

    func testProvidedDocumentWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCANSTUDIO_CLASSIFICATION_SAMPLE"] else { throw XCTSkip("Nessun documento di prova configurato") }
        let image = try XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await DocumentOCR.recognize(image)
        let fallback = DocumentRecognizer.classify(result.text)
        let info = await DocumentRecognizer.analyze(result)
        print("Tipo rilevato: \(info.kind.fileLabel); euristica: \(fallback.fileLabel)")
        XCTAssertFalse(result.lines.isEmpty)
    }
}
