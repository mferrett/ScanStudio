import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ExportError: LocalizedError {
    case renderFailed(Int)
    case cannotCreate(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let page): return "Elaborazione della pagina \(page) non riuscita."
        case .cannotCreate(let name): return "Impossibile creare il file \(name)."
        case .writeFailed(let name): return "Scrittura del file \(name) non riuscita."
        }
    }
}

enum Exporter {

    /// Esporta le pagine e restituisce gli URL dei file scritti.
    static func export(pages: [ScannedPage],
                       options: ExportOptions,
                       to url: URL,
                       progress: @escaping (Double) -> Void) throws -> [URL] {
        switch options.format {
        case .pdf:
            try writePDF(pages: pages, options: options, to: url, progress: progress)
            return [url]
        case .tiff:
            try writeMultiPageTIFF(pages: pages, to: url, progress: progress)
            return [url]
        case .png, .jpeg:
            return try writeSeparateFiles(pages: pages, options: options, base: url, progress: progress)
        }
    }

    private static func rendered(_ page: ScannedPage, index: Int) throws -> CGImage {
        guard let img = ImageProcessor.render(page.full, adjustments: page.adjustments,
                                              mode: page.mode, quarterTurns: page.quarterTurns) else {
            throw ExportError.renderFailed(index + 1)
        }
        return img
    }

    // MARK: - PDF

    private static func writePDF(pages: [ScannedPage], options: ExportOptions, to url: URL,
                                 progress: @escaping (Double) -> Void) throws {
        let info = [kCGPDFContextCreator: "ScanStudio"] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, info) else {
            throw ExportError.cannotCreate(url.lastPathComponent)
        }
        for (i, page) in pages.enumerated() {
            try autoreleasepool {
                let image = try rendered(page, index: i)
                var mediaBox = CGRect(x: 0, y: 0,
                                      width: CGFloat(image.width) * 72 / page.dpi,
                                      height: CGFloat(image.height) * 72 / page.dpi)
                let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
                ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)

                let drawable: CGImage
                switch page.mode {
                case .blackWhite:
                    drawable = ImageUtilities.oneBit(image) ?? image
                case .grayscale, .color:
                    let base = page.mode == .color ? ImageUtilities.opaqueRGB(image) : image
                    drawable = options.pdfUseJPEG ? ImageUtilities.jpegBacked(base, quality: options.jpegQuality) : base
                }
                ctx.interpolationQuality = .high
                ctx.draw(drawable, in: mediaBox)

                if options.ocr {
                    let lines = TextRecognizer.recognize(image)
                    TextRecognizer.drawInvisible(lines, in: ctx, pageRect: mediaBox)
                }
                ctx.endPDFPage()
            }
            progress(Double(i + 1) / Double(pages.count))
        }
        ctx.closePDF()
    }

    // MARK: - TIFF multipagina

    private static func writeMultiPageTIFF(pages: [ScannedPage], to url: URL,
                                           progress: @escaping (Double) -> Void) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, pages.count, nil) else {
            throw ExportError.cannotCreate(url.lastPathComponent)
        }
        for (i, page) in pages.enumerated() {
            try autoreleasepool {
                let image = try rendered(page, index: i)
                let final = prepared(image, mode: page.mode, format: .tiff)
                CGImageDestinationAddImage(dest, final, properties(dpi: page.dpi, format: .tiff, quality: 1) as CFDictionary)
            }
            progress(Double(i + 1) / Double(pages.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed(url.lastPathComponent) }
    }

    // MARK: - PNG / JPEG (un file per pagina)

    private static func writeSeparateFiles(pages: [ScannedPage], options: ExportOptions, base: URL,
                                           progress: @escaping (Double) -> Void) throws -> [URL] {
        let folder = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = options.format.fileExtension
        var written: [URL] = []

        for (i, page) in pages.enumerated() {
            let url = pages.count == 1
                ? base
                : folder.appendingPathComponent(String(format: "%@-%03d.%@", stem, i + 1, ext))
            try autoreleasepool {
                let image = try rendered(page, index: i)
                let final = prepared(image, mode: page.mode, format: options.format)
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
                    throw ExportError.cannotCreate(url.lastPathComponent)
                }
                CGImageDestinationAddImage(dest, final,
                                           properties(dpi: page.dpi, format: options.format, quality: options.jpegQuality) as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed(url.lastPathComponent) }
            }
            written.append(url)
            progress(Double(i + 1) / Double(pages.count))
        }
        return written
    }

    private static func prepared(_ image: CGImage, mode: ColorMode, format: ExportFormat) -> CGImage {
        switch mode {
        case .color:
            return ImageUtilities.opaqueRGB(image)
        case .grayscale:
            return image
        case .blackWhite:
            // Il JPEG non supporta 1 bit: resta in grigi a 8 bit
            return format == .jpeg ? image : (ImageUtilities.oneBit(image) ?? image)
        }
    }

    private static func properties(dpi: Double, format: ExportFormat, quality: Double) -> [CFString: Any] {
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        switch format {
        case .jpeg:
            props[kCGImageDestinationLossyCompressionQuality] = quality
        case .tiff:
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
        default:
            break
        }
        return props
    }
}

// MARK: - OCR (testo ricercabile nel PDF)

enum TextRecognizer {

    struct Line {
        let text: String
        let box: CGRect   // normalizzato, origine in basso a sinistra (come il PDF)
    }

    static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return Line(text: candidate.string, box: obs.boundingBox)
        }
    }

    /// Disegna il testo in modalità invisibile sopra l'immagine:
    /// il PDF diventa selezionabile e ricercabile senza cambiare aspetto.
    static func drawInvisible(_ lines: [Line], in ctx: CGContext, pageRect: CGRect) {
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: pageRect.minX + line.box.minX * pageRect.width,
                              y: pageRect.minY + line.box.minY * pageRect.height,
                              width: line.box.width * pageRect.width,
                              height: line.box.height * pageRect.height)
            guard rect.width > 1, rect.height > 1 else { continue }

            let fontSize = max(1, rect.height * 0.85)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: line.text,
                                                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard lineWidth > 0 else { continue }

            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.textMatrix = .identity
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.18)
            ctx.scaleBy(x: rect.width / lineWidth, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }
}
