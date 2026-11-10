import XCTest
@testable import ScanStudio

final class ScannerProgressTests: XCTestCase {
    func testOnlyDriverReportedProgressIsPresented() {
        XCTAssertNil(ScannerProgress.fraction(percent: 0, inProgress: true))
        XCTAssertNil(ScannerProgress.fraction(percent: -1, inProgress: true))
        XCTAssertNil(ScannerProgress.fraction(percent: 101, inProgress: true))
        XCTAssertNil(ScannerProgress.fraction(percent: .nan, inProgress: true))
        XCTAssertNil(ScannerProgress.fraction(percent: 55, inProgress: false))
        XCTAssertEqual(ScannerProgress.fraction(percent: 55, inProgress: true), 0.55)
        XCTAssertEqual(ScannerProgress.fraction(percent: 100, inProgress: true), 1)
    }
}
