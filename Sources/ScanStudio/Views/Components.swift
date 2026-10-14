import SwiftUI
import CoreGraphics

/// Rettangolo con proporzioni `content` adattato dentro `bounds`
func fittedRect(content: CGSize, in bounds: CGRect) -> CGRect {
    guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
}

/// Mostra un'immagine con le regolazioni applicate, elaborata in background.
struct ProcessedImageView: View {
    let source: CGImage
    let adjustments: Adjustments
    let mode: ColorMode
    var quarterTurns: Int = 0

    @State private var rendered: CGImage?

    private struct RenderKey: Hashable {
        let source: ObjectIdentifier
        let adjustments: Adjustments
        let mode: ColorMode
        let turns: Int
    }

    var body: some View {
        ZStack {
            if let rendered {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: RenderKey(source: ObjectIdentifier(source), adjustments: adjustments,
                            mode: mode, turns: quarterTurns)) {
            // piccolo ritardo: evita di elaborare ogni passo mentre si trascina uno slider
            if rendered != nil {
                try? await Task.sleep(for: .milliseconds(35))
                if Task.isCancelled { return }
            }
            let src = source, adj = adjustments, m = mode, t = quarterTurns
            let output = await Task.detached(priority: .userInitiated) {
                ImageProcessor.render(src, adjustments: adj, mode: m, quarterTurns: t)
            }.value
            if !Task.isCancelled, let output {
                rendered = output
            }
        }
    }
}

/// Riga con titolo, valore e slider. Doppio clic sul titolo = ripristina.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { value = defaultValue }
                    .help("Doppio clic per ripristinare")
                Spacer()
                Text(range.lowerBound < 0 && value.rounded() != 0
                     ? String(format: "%+.0f", value)
                     : "\(Int(value.rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
        .contextMenu {
            Button("Ripristina") { value = defaultValue }
        }
    }
}

/// Velo con avanzamento per operazioni lunghe
struct BusyOverlay: View {
    let message: String
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(message).font(.headline)
                ProgressView(value: progress)
                    .frame(width: 260)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
