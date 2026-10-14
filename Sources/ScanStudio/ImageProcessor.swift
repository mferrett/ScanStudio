import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO

/// Pipeline di elaborazione basata su Core Image (accelerata via GPU).
/// Le regolazioni sono applicate in software: ImageCaptureCore non espone
/// in modo uniforme i controlli hardware di luminosità/contrasto degli scanner.
enum ImageProcessor {

    static let context = CIContext(options: [.cacheIntermediates: false])

    private static let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]

    static func pipeline(_ source: CIImage,
                         adjustments a: Adjustments,
                         mode: ColorMode,
                         quarterTurns: Int) -> CIImage {
        var img = source

        // Rotazione
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = img.oriented(orientations[turns])
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let extent = img.extent

        // Miglioramento automatico
        if a.autoEnhance {
            for filter in img.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(img, forKey: kCIInputImageKey)
                if let out = filter.outputImage { img = out }
            }
        }

        // Riduzione rumore
        if a.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = img
            f.noiseLevel = Float(a.noiseReduction / 100 * 0.08)
            f.sharpness = 0.4
            img = f.outputImage ?? img
        }

        // Brillantezza (esposizione, in stop)
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(a.exposure / 100 * 2)
            img = f.outputImage ?? img
        }

        // Toni medi (gamma)
        if a.gamma != 0 {
            let f = CIFilter.gammaAdjust()
            f.inputImage = img
            f.power = Float(pow(2, -a.gamma / 100))
            img = f.outputImage ?? img
        }

        // Luminosità, contrasto, saturazione
        let cc = CIFilter.colorControls()
        cc.inputImage = img
        cc.brightness = Float(a.brightness / 100 * 0.5)
        cc.contrast = Float(pow(2, a.contrast / 100))
        cc.saturation = mode == .color ? Float(1 + a.saturation / 100) : 0
        img = cc.outputImage ?? img

        // Nitidezza
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(a.sharpness / 100 * 2)
            f.radius = 1.5
            img = f.outputImage ?? img
        }

        // Negativo
        if a.invert {
            let f = CIFilter.colorInvert()
            f.inputImage = img
            img = f.outputImage ?? img
        }

        // Bianco e nero: soglia
        if mode == .blackWhite {
            let f = CIFilter.colorThreshold()
            f.inputImage = img
            f.threshold = Float(a.threshold / 100)
            img = f.outputImage ?? img
        }

        return img.cropped(to: extent)
    }

    /// Restituisce un CGImage RGB (colore) oppure in scala di grigi a 8 bit (grigi / B/N).
    static func render(_ image: CGImage,
                       adjustments: Adjustments,
                       mode: ColorMode,
                       quarterTurns: Int) -> CGImage? {
        let output = pipeline(CIImage(cgImage: image), adjustments: adjustments, mode: mode, quarterTurns: quarterTurns)
        if mode == .color {
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space)
        } else {
            return context.createCGImage(output, from: output.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
    }
}
