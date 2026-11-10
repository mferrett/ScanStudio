import XCTest
@testable import ScanStudio

final class LocalizationTests: XCTestCase {
    func testTranslationsArePackagedAndContainPlaceholders() throws {
        let translations = ["it": "Salva", "en": "Save", "es": "Guardar", "fr": "Enregistrer", "de": "Sichern", "pt": "Salvar"]
        for (language, expected) in translations {
            let path = try XCTUnwrap(localizationBundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Salva", value: nil, table: nil), expected, language)
            let pageFormat = bundle.localizedString(forKey: "Pagina %lld di %lld", value: nil, table: nil)
            XCTAssertEqual(pageFormat.components(separatedBy: "%lld").count - 1, 2, language)
        }
    }
}
