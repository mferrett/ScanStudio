import CoreGraphics
import Foundation
import CoreImage
import ImageIO
import Vision

/// Compone fronte e retro di un documento di identità in un'unica pagina A4, senza sovrapposizioni.
enum IDCardComposer {

    static func compose(front: CGImage, frontDPI: Double,
                        back: CGImage, backDPI: Double,
                        autoCrop: Bool) -> CGImage? {
        let dpi = min(max(frontDPI, backDPI), 600)
        let canvasW = Int((8.27 * dpi).rounded())
        let canvasH = Int((11.69 * dpi).rounded())
        let margin = CGFloat(canvasW) * 0.08
        let slotW = CGFloat(canvasW) - 2 * margin
        let slotH = (CGFloat(canvasH) - 3 * margin) / 2

        guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.interpolationQuality = .high

        let sides = [(prepare(front, autoCrop: autoCrop), frontDPI), (prepare(back, autoCrop: autoCrop), backDPI)]
        for (index, (image, sideDPI)) in sides.enumerated() {
            // Dimensione fisica del lato riportata alla risoluzione della pagina
            let ratio = dpi / sideDPI
            let w = CGFloat(image.width) * ratio, h = CGFloat(image.height) * ratio
            let scale = min(slotW / w, slotH / h, 1)
            let dw = w * scale, dh = h * scale
            // Origine in basso a sinistra: il fronte sta nello slot superiore
            let slotBottom = index == 0 ? CGFloat(canvasH) - margin - slotH : margin
            let rect = CGRect(x: (CGFloat(canvasW) - dw) / 2,
                              y: slotBottom + (slotH - dh) / 2,
                              width: dw, height: dh)
            ctx.draw(image, in: rect)
        }
        return ctx.makeImage()
    }

    /// Ritaglio del documento (se richiesto), raddrizzamento dell'inclinazione e rotazione in orizzontale.
    static func prepare(_ image: CGImage, autoCrop: Bool) -> CGImage {
        var result = image
        if autoCrop {
            if let straight = deskewedCard(image) {
                result = straight
            } else if let r = ImageUtilities.detectDocument(in: image) {
                let rect = CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                                  width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral
                // Ignora ritagli irrilevanti o troppo piccoli per essere un documento
                if rect.width > CGFloat(image.width) * 0.15, rect.height > CGFloat(image.height) * 0.15,
                   let cropped = image.cropping(to: rect) {
                    result = cropped
                }
            }
        }
        return upright(result)
    }

    /// Se la carta è appoggiata storta (inclinazione fra 0,4° e 45°) la ritaglia e la raddrizza.
    /// Restituisce nil se non trova una carta o se è già dritta: in quel caso basta il ritaglio normale.
    private static func deskewedCard(_ image: CGImage) -> CGImage? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 6
        request.minimumConfidence = 0.6
        request.minimumSize = 0.15
        request.minimumAspectRatio = 0.4
        request.quadratureTolerance = 20
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let found = request.results else { return nil }

        let w = CGFloat(image.width), h = CGFloat(image.height)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        // Fra i rettangoli con proporzioni da carta (ID-1: 85,6 × 54 mm) prende il più grande
        let best = found
            .map { (obs: $0, tl: px($0.topLeft), tr: px($0.topRight), bl: px($0.bottomLeft), br: px($0.bottomRight)) }
            .filter { c in
                let a = dist(c.tl, c.tr), b = dist(c.tl, c.bl)
                let ratio = min(a, b) / max(a, b)
                return ratio > 0.52 && ratio < 0.78
            }
            .max { dist($0.tl, $0.tr) * dist($0.tl, $0.bl) < dist($1.tl, $1.tr) * dist($1.tl, $1.bl) }
        guard let card = best else { return nil }

        // Inclinazione del lato superiore, ripiegata in -45…45°
        var tilt = atan2(card.tr.y - card.tl.y, card.tr.x - card.tl.x) * 180 / .pi
        tilt = tilt.truncatingRemainder(dividingBy: 90)
        if tilt > 45 { tilt -= 90 } else if tilt < -45 { tilt += 90 }
        guard abs(tilt) >= 0.4 else { return nil }

        let filter = CIFilter(name: "CIPerspectiveCorrection")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: card.tl), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: card.tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: card.bl), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: card.br), forKey: "inputBottomRight")
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        return context.createCGImage(output, from: output.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Porta il documento in orizzontale e dritto. Se è già orizzontale decide fra 0° e 180°,
    /// se è verticale fra 90° e 270°, in base al verso di lettura del testo.
    /// In assenza di testo sufficiente mantiene l'orientamento predefinito.
    static func upright(_ image: CGImage) -> CGImage {
        let landscape = image.width >= image.height
        let candidates: [(turns: Int, alternative: Int, orientation: CGImagePropertyOrientation)] =
            landscape ? [(0, 2, .up)] : [(1, 3, .right)]
        let c = candidates[0]
        let small = ImageUtilities.downscale(image, maxSide: 1800)
        let direction = readingDirection(small, orientation: c.orientation)
        return rotate(image, quarterTurns: direction < -minimumDirectionEvidence ? c.alternative : c.turns)
    }

    private static let minimumDirectionEvidence = 0.12

    /// Verso di lettura del testo nell'orientamento dato: positivo se le righe vanno da sinistra
    /// a destra (immagine dritta), negativo se vanno da destra a sinistra (capovolta).
    /// Vision legge anche il testo capovolto restituendo la stringa nel verso corretto, ma le
    /// posizioni dei caratteri restano quelle reali: confrontando primo e ultimo carattere
    /// di ogni riga si ricava il verso. Il valore è la somma, pesata per lunghezza, degli spostamenti.
    private static func readingDirection(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return 0 }

        var total = 0.0
        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard text.count >= 4, text.filter(\.isLetter).count >= 3 else { continue }
            let head = text.startIndex..<text.index(text.startIndex, offsetBy: 2)
            let tail = text.index(text.endIndex, offsetBy: -2)..<text.endIndex
            guard let first = try? candidate.boundingBox(for: head),
                  let last = try? candidate.boundingBox(for: tail) else { continue }
            let delta = Double(last.boundingBox.midX - first.boundingBox.midX)
            // Ignora le righe con primo e ultimo carattere sovrapposti (ripetizioni, simboli)
            if abs(delta) > 0.02 { total += delta }
        }
        return total
    }

    /// Rotazione oraria in quarti di giro.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return image }
        let w = image.width, h = image.height
        let swap = turns % 2 == 1
        let cw = swap ? h : w, ch = swap ? w : h
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.translateBy(x: CGFloat(cw) / 2, y: CGFloat(ch) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }
}
