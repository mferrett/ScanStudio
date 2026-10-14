import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageUtilities {

    struct LoadedImage {
        let image: CGImage
        let dpi: Double?
    }

    // MARK: - Caricamento

    static func load(data: Data) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source, at: 0)
    }

    /// Carica tutte le pagine di un file (immagini multipagina e PDF)
    static func loadPages(from url: URL) -> [LoadedImage] {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) {
            return renderPDF(url: url, dpi: 200)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        return (0..<count).compactMap { image(from: source, at: $0) }
    }

    private static func image(from source: CGImageSource, at index: Int) -> LoadedImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let img = CGImageSourceCreateImageAtIndex(source, index, options) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        return LoadedImage(image: img, dpi: (dpi ?? 0) > 1 ? dpi : nil)
    }

    private static func renderPDF(url: URL, dpi: CGFloat) -> [LoadedImage] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return [] }
        var result: [LoadedImage] = []
        let scale = dpi / 72
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index) else { continue }
            let box = page.getBoxRect(.cropBox)
            let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
            let rotated = angle == 90 || angle == 270
            let w = rotated ? box.height : box.width
            let h = rotated ? box.width : box.height
            let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())
            guard pw > 0, ph > 0,
                  let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            switch angle {
            case 90:  ctx.translateBy(x: 0, y: h); ctx.rotate(by: -.pi / 2)
            case 180: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
            case 270: ctx.translateBy(x: w, y: 0); ctx.rotate(by: .pi / 2)
            default: break
            }
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            if let img = ctx.makeImage() {
                result.append(LoadedImage(image: img, dpi: Double(dpi)))
            }
        }
        return result
    }

    // MARK: - Conversioni

    /// Riduce l'immagine in modo che il lato maggiore non superi maxSide pixel
    static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(1, maxSide / max(w, h))
        if s >= 1 { return image }
        let nw = max(1, Int(w * s)), nh = max(1, Int(h * s))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// Copia RGB senza canale alfa (file PNG/TIFF più leggeri)
    static func opaqueRGB(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Pixel in scala di grigi a 8 bit (una riga = width byte)
    static func gray8(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = width ?? image.width, h = height ?? image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    /// Converte in bitmap a 1 bit (bianco e nero puro): file PDF/PNG/TIFF molto compatti
    static func oneBit(_ image: CGImage) -> CGImage? {
        guard let gray = gray8(image) else { return nil }
        let w = gray.width, h = gray.height
        let bytesPerRow = (w + 7) / 8
        var packed = [UInt8](repeating: 0, count: bytesPerRow * h)
        gray.pixels.withUnsafeBufferPointer { src in
            packed.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let inRow = y * w
                    let outRow = y * bytesPerRow
                    for x in 0..<w where src[inRow + x] >= 128 {
                        dst[outRow + (x >> 3)] |= UInt8(0x80) >> UInt8(x & 7)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(packed) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Ricodifica in JPEG: Quartz incorpora i dati DCT direttamente nel PDF
    static func jpegBacked(_ image: CGImage, quality: Double) -> CGImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return image }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return jpeg
    }

    // MARK: - Rilevamento documento

    /// Restituisce il riquadro del documento sull'anteprima (normalizzato, origine in alto a sinistra)
    static func detectDocument(in image: CGImage) -> CGRect? {
        if let rect = detectRectangle(in: image) { return rect }
        return contentBounds(in: image)
    }

    private static func detectRectangle(in image: CGImage) -> CGRect? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.5
        request.minimumSize = 0.15
        request.minimumAspectRatio = 0.2
        request.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let box = request.results?.first?.boundingBox else { return nil }
        let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        return clampUnit(rect.insetBy(dx: -0.004, dy: -0.004))
    }

    /// Ripiego: individua l'area che differisce dal colore del coperchio
    private static func contentBounds(in image: CGImage) -> CGRect? {
        let maxSide: CGFloat = 400
        let s = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = max(8, Int(CGFloat(image.width) * s)), h = max(8, Int(CGFloat(image.height) * s))
        guard let gray = gray8(image, width: w, height: h) else { return nil }
        let px = gray.pixels

        var border: [UInt8] = []
        for x in 0..<w { border.append(px[x]); border.append(px[(h - 1) * w + x]) }
        for y in 0..<h { border.append(px[y * w]); border.append(px[y * w + w - 1]) }
        border.sort()
        let background = Int(border[border.count / 2])

        var colCount = [Int](repeating: 0, count: w)
        var rowCount = [Int](repeating: 0, count: h)
        for y in 0..<h {
            for x in 0..<w where abs(Int(px[y * w + x]) - background) > 30 {
                colCount[x] += 1
                rowCount[y] += 1
            }
        }
        let colMin = max(2, h / 100), rowMin = max(2, w / 100)
        guard let x0 = colCount.firstIndex(where: { $0 >= colMin }),
              let x1 = colCount.lastIndex(where: { $0 >= colMin }),
              let y0 = rowCount.firstIndex(where: { $0 >= rowMin }),
              let y1 = rowCount.lastIndex(where: { $0 >= rowMin }),
              x1 > x0, y1 > y0 else { return nil }
        let rect = CGRect(x: CGFloat(x0) / CGFloat(w), y: CGFloat(y0) / CGFloat(h),
                          width: CGFloat(x1 - x0 + 1) / CGFloat(w), height: CGFloat(y1 - y0 + 1) / CGFloat(h))
        guard rect.width > 0.05, rect.height > 0.05 else { return nil }
        return clampUnit(rect.insetBy(dx: -0.015, dy: -0.015))
    }

    static func clampUnit(_ rect: CGRect) -> CGRect {
        rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
