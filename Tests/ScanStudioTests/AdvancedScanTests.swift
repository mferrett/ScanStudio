import XCTest
import AppKit
import PDFKit
@testable import ScanStudio

final class AdvancedScanTests: XCTestCase {
    private func plainImage() throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        return try XCTUnwrap(context.makeImage())
    }
    func testOldAdjustmentsStillDecodeAndAdvancedFiltersApply() throws {
        let legacy = Data(#"{"brightness":0,"contrast":0,"exposure":0,"gamma":0,"saturation":0,"sharpness":0,"noiseReduction":0,"threshold":50,"autoEnhance":false,"invert":false}"#.utf8)
        var settings = try JSONDecoder().decode(Adjustments.self, from: legacy)
        XCTAssertEqual(settings.advanced.descreen, 0)
        let previous = Data(#"{"brightness":0,"contrast":0,"exposure":0,"gamma":0,"saturation":0,"sharpness":0,"noiseReduction":0,"threshold":50,"autoEnhance":false,"invert":false,"advancedStorage":{"deskew":true,"descreen":30,"dustRemoval":false,"restoreColors":true,"blackPoint":10,"whitePoint":90,"midtone":50,"curveShadows":25,"curveHighlights":75,"gutter":15,"gutterOnRight":false}}"#.utf8)
        let restored = try JSONDecoder().decode(Adjustments.self, from: previous)
        XCTAssertTrue(restored.advanced.deskew)
        XCTAssertEqual(restored.advanced.descreen, 30)
        XCTAssertEqual(restored.advanced.gutter, 15)
        let image = try plainImage()
        let baseline = try XCTUnwrap(ImageProcessor.render(image, adjustments: settings, mode: .color, quarterTurns: 0))
        settings.advanced.dustRemoval = true
        settings.advanced.descreen = 15
        settings.advanced.restoreColors = true
        let changed = try XCTUnwrap(ImageProcessor.render(image, adjustments: settings, mode: .color, quarterTurns: 0))
        let originalPixels = try XCTUnwrap(ImageUtilities.gray8(baseline)).pixels
        let changedPixels = try XCTUnwrap(ImageUtilities.gray8(changed)).pixels
        XCTAssertNotEqual(originalPixels[originalPixels.count / 2], changedPixels[changedPixels.count / 2])
        XCTAssertEqual(changed.width, image.width)
    }
    private func multiCropFixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        for rect in [CGRect(x: 100, y: 480, width: 370, height: 300), CGRect(x: 700, y: 480, width: 360, height: 300), CGRect(x: 350, y: 70, width: 380, height: 280)] { context.fill(rect) }
        return try XCTUnwrap(context.makeImage())
    }
    func testMultiCropSeparatesDistinctRectangles() throws {
        let parts = ImageUtilities.splitDocuments(try multiCropFixture())
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.width > 250 && $0.height > 200 })
    }
    @MainActor
    func testMultiCropLimitsDefaultExportToNewItems() async throws {
        let model = AppModel(scanner: ScannerManager(discoverDevices: false), persistSettings: false)
        let image = try multiCropFixture()
        model.addPage(image, dpi: 150, mode: .color, adjustments: .neutral)
        let previousID = try XCTUnwrap(model.pages.first?.id)
        model.processMultiCrop(image, dpi: 150)
        for _ in 0..<100 {
            if model.busyMessage == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.multiCropPages.count, 3)
        XCTAssertFalse(model.multiCropPageIDs.contains(previousID))
        XCTAssertEqual(model.exportOptions.scope, .multiCrop)
        XCTAssertEqual(model.exportOptions.format, .pdfSingle)
        model.addMultiCropOriginal()
        XCTAssertEqual(model.pages.count, 5)
        XCTAssertEqual(model.multiCropPages.count, 3)
    }
    func testDeskewStraightensTiltedPage() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        context.translateBy(x: 500, y: 400)
        context.rotate(by: 0.09)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: -400, y: -300, width: 800, height: 600))
        let image = try XCTUnwrap(context.makeImage())
        let corrected = try XCTUnwrap(ImageUtilities.deskew(image))
        XCTAssertLessThan(abs(Double(corrected.width) / Double(corrected.height) - 4.0 / 3.0), 0.07)
    }
    func testGutterBrightensChosenEdge() throws {
        let image = try plainImage()
        var settings = Adjustments()
        settings.advanced.gutter = 100
        let rendered = try XCTUnwrap(ImageProcessor.render(image, adjustments: settings, mode: .color, quarterTurns: 0))
        let pixels = try XCTUnwrap(ImageUtilities.gray8(rendered)).pixels
        let middle = 64 * 128
        XCTAssertGreaterThan(pixels[middle + 2], pixels[middle + 64])
        settings.advanced.gutterOnRight = true
        let right = try XCTUnwrap(ImageProcessor.render(image, adjustments: settings, mode: .color, quarterTurns: 0))
        let rightPixels = try XCTUnwrap(ImageUtilities.gray8(right)).pixels
        XCTAssertGreaterThan(rightPixels[middle + 125], rightPixels[middle + 64])
    }
    func testSeparatePDFAndTIFFDoNotOverwriteExistingPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try plainImage()
        func page() -> ScannedPage { ScannedPage(full: image, preview: image, thumbnail: image, dpi: 150, mode: .color, adjustments: .neutral) }
        for format in [ExportFormat.pdfSingle, .tiffSingle] {
            var options = ExportOptions()
            options.format = format
            let base = directory.appendingPathComponent("scan").appendingPathExtension(format.fileExtension)
            let existing = directory.appendingPathComponent("scan-001").appendingPathExtension(format.fileExtension)
            try Data("preserve".utf8).write(to: existing)
            let written = try await Exporter.export(pages: [page(), page()], options: options, to: base) { _ in }
            XCTAssertEqual(written.count, 2)
            XCTAssertEqual(try Data(contentsOf: existing), Data("preserve".utf8))
            XCTAssertTrue(written.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            if format.isPDF { XCTAssertTrue(written.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }) }
        }
    }
}
