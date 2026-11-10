import XCTest
@testable import ScanStudio

final class MarkdownStructureTests: XCTestCase {
    func testRolesKeepOriginalTextAndExistingTable() {
        let blocks = ["Fattura", "Numero: 42", "| Articolo | Prezzo |\n| --- | --- |\n| Carta | 5 |", "Pagamento"]
        let roles = MarkdownStructure.Roles(headings: [0, 2], listItems: [3])
        let result = MarkdownStructure.apply(roles, to: blocks, eligibleCount: blocks.count)
        XCTAssertEqual(result, "## Fattura\n\nNumero: 42\n\n\(blocks[2])\n\n- Pagamento")
        XCTAssertTrue(MarkdownStructure.formatFields(result).contains("**Numero:** 42"))
    }

    func testInvalidModelIndicesCannotRemoveOrChangeContent() {
        let blocks = ["Titolo", "Importo: 15 €"]
        let roles = MarkdownStructure.Roles(headings: [0, 20], listItems: [])
        XCTAssertEqual(MarkdownStructure.apply(roles, to: blocks, eligibleCount: 2), blocks.joined(separator: "\n\n"))
    }
}
