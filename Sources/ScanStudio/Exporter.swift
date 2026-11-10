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
    case markdownFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let page): return localizedFormat("Elaborazione della pagina %lld non riuscita.", page)
        case .cannotCreate(let name): return localizedFormat("Impossibile creare il file %@.", name)
        case .markdownFailed(let reason): return localizedFormat("La scansione è stata salvata, ma il Markdown non è stato creato: %@", reason)
        case .writeFailed(let name): return localizedFormat("Scrittura del file %@ non riuscita.", name)
        }
    }
}

enum Exporter {

    /// Esporta le pagine e restituisce gli URL dei file scritti.
    static func export(pages: [ScannedPage],
                       options: ExportOptions,
                       to url: URL,
                       progress: @escaping (Double) -> Void) async throws -> [URL] {
        let needsOCR = options.exportMarkdown || options.format.isPDF
        var recognized: [DocumentOCRResult] = []
        if needsOCR {
            for (index, page) in pages.enumerated() {
                recognized.append(try await DocumentOCRCache.shared.recognize(page))
                progress(0.5 * Double(index + 1) / Double(pages.count))
            }
        }
        let report: (Double) -> Void = { progress(needsOCR ? 0.5 + $0 * 0.5 : $0) }
        var written: [URL]
        if options.format.isSeparateDocument && pages.count > 1 && (options.format.isPDF || options.format == .tiffSingle) {
            written = []
            for (index, page) in pages.enumerated() {
                let candidate = numberedURL(base: url, index: index)
                let destination = uniqueURL(candidate)
                switch options.format {
                case .pdf, .pdfSingle:
                    let pageOCR = needsOCR ? [recognized[index]] : []
                    try writePDF(pages: [page], options: options, recognized: pageOCR, to: destination) { _ in }
                case .tiff, .tiffSingle:
                    try writeMultiPageTIFF(pages: [page], to: destination) { _ in }
                case .png, .jpeg: break
                }
                written.append(destination)
                report(Double(index + 1) / Double(pages.count))
            }
        } else {
            switch options.format {
            case .pdf, .pdfSingle:
                try writePDF(pages: pages, options: options, recognized: recognized, to: url, progress: report)
                written = [url]
            case .tiff, .tiffSingle:
                try writeMultiPageTIFF(pages: pages, to: url, progress: report)
                written = [url]
            case .png, .jpeg:
                written = try writeSeparateFiles(pages: pages, options: options, base: url, progress: report)
            }
        }
        if options.exportMarkdown {
            var structured: [String] = []
            for result in recognized { structured.append(await MarkdownStructure.enrich(result.markdown)) }
            if (options.format == .pdfSingle || options.format == .tiffSingle || (options.scope == .multiCrop && options.format.isSeparateDocument)) && written.count == recognized.count && written.count > 1 {
                let scanFiles = written
                for (index, scan) in scanFiles.enumerated() {
                    let destination = uniqueURL(scan.deletingPathExtension().appendingPathExtension("md"))
                    do { try (structured[index] + "\n").write(to: destination, atomically: true, encoding: .utf8) }
                    catch { throw ExportError.markdownFailed(error.localizedDescription) }
                    written.append(destination)
                }
            } else {
                let destination = uniqueURL(url.deletingPathExtension().appendingPathExtension("md"))
                let markdown = structured.enumerated().map { index, markdown in
                    structured.count > 1 ? "## \(localizedFormat("Pagina %lld", index + 1))\n\n\(markdown)" : markdown
                }.joined(separator: "\n\n---\n\n") + "\n"
                do { try markdown.write(to: destination, atomically: true, encoding: .utf8) }
                catch { throw ExportError.markdownFailed(error.localizedDescription) }
                written.append(destination)
            }
        }
        return written
    }

    private static func numberedURL(base: URL, index: Int) -> URL {
        let folder = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent(String(format: "%@-%03d", stem, index + 1)).appendingPathExtension(base.pathExtension)
    }

    private static func uniqueURL(_ candidate: URL) -> URL {
        var result = candidate
        var suffix = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = candidate.deletingLastPathComponent()
                .appendingPathComponent("\(candidate.deletingPathExtension().lastPathComponent) \(suffix)")
                .appendingPathExtension(candidate.pathExtension)
            suffix += 1
        }
        return result
    }

    private static func rendered(_ page: ScannedPage, index: Int) throws -> CGImage {
        guard let img = ImageProcessor.render(page.full, adjustments: page.adjustments,
                                              mode: page.mode, quarterTurns: page.quarterTurns) else {
            throw ExportError.renderFailed(index + 1)
        }
        return img
    }

    // MARK: - PDF

    private static func writePDF(pages: [ScannedPage], options: ExportOptions, recognized: [DocumentOCRResult], to url: URL,
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

                TextRecognizer.drawInvisible(recognized[i].lines, in: ctx, pageRect: mediaBox)
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
                : uniqueURL(folder.appendingPathComponent(String(format: "%@-%03d.%@", stem, i + 1, ext)))
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

    /// Disegna il testo in modalità invisibile sopra l'immagine:
    /// il PDF diventa selezionabile e ricercabile senza cambiare aspetto.
    static func drawInvisible(_ lines: [DocumentOCRResult.Line], in ctx: CGContext, pageRect: CGRect) {
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
