import SwiftUI

/// Strumento di selezione dell'area: trascina per creare, sposta trascinando
/// all'interno, ridimensiona da bordi e angoli.
struct SelectionOverlay: View {
    /// Normalizzata 0…1, origine in alto a sinistra
    @Binding var selection: CGRect
    /// Dove si trova l'immagine dentro la vista
    let imageFrame: CGRect
    /// Dimensioni fisiche del piano, in pollici (per l'etichetta)
    let physicalSize: CGSize
    var enabled: Bool = true

    @State private var startSelection: CGRect?
    @State private var dragKind: DragKind = .none
    @State private var dragEdges: Edges = []

    private enum DragKind { case none, create, move, resize }

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private struct Handle: Identifiable {
        let id: Int
        let point: CGPoint
    }

    private var viewRect: CGRect {
        CGRect(x: imageFrame.minX + selection.minX * imageFrame.width,
               y: imageFrame.minY + selection.minY * imageFrame.height,
               width: selection.width * imageFrame.width,
               height: selection.height * imageFrame.height)
    }

    var body: some View {
        let r = viewRect
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(imageFrame)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            Path { p in p.addRect(r) }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))

            if enabled {
                ForEach(handles(for: r)) { handle in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .position(handle.point)
                }
            }

            Text(sizeLabel)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .position(x: r.midX, y: max(r.minY - 14, imageFrame.minY + 12))
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture, including: enabled ? .all : .subviews)
    }

    private var sizeLabel: String {
        let fmt = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        let w = Double(selection.width * physicalSize.width * 2.54)
        let h = Double(selection.height * physicalSize.height * 2.54)
        return "\(w.formatted(fmt)) × \(h.formatted(fmt)) cm"
    }

    private func handles(for r: CGRect) -> [Handle] {
        [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ].enumerated().map { Handle(id: $0.offset, point: $0.element) }
    }

    // MARK: - Gesto

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startSelection == nil { begin(at: value.startLocation) }
                update(translation: value.translation, start: value.startLocation, current: value.location)
            }
            .onEnded { _ in
                if selection.width < 0.01 || selection.height < 0.01 {
                    selection = startSelection ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                startSelection = nil
                dragKind = .none
                dragEdges = []
            }
    }

    private func begin(at p: CGPoint) {
        startSelection = selection
        let r = viewRect
        let tol: CGFloat = 8
        let withinY = p.y >= r.minY - tol && p.y <= r.maxY + tol
        let withinX = p.x >= r.minX - tol && p.x <= r.maxX + tol
        var edges: Edges = []
        if withinY && abs(p.x - r.minX) <= tol { edges.insert(.left) }
        if withinY && abs(p.x - r.maxX) <= tol { edges.insert(.right) }
        if withinX && abs(p.y - r.minY) <= tol { edges.insert(.top) }
        if withinX && abs(p.y - r.maxY) <= tol { edges.insert(.bottom) }

        if !edges.isEmpty {
            dragKind = .resize
            dragEdges = edges
        } else if r.contains(p) {
            dragKind = .move
        } else if imageFrame.insetBy(dx: -tol, dy: -tol).contains(p) {
            dragKind = .create
        } else {
            dragKind = .none
        }
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max((p.x - imageFrame.minX) / imageFrame.width, 0), 1),
                y: min(max((p.y - imageFrame.minY) / imageFrame.height, 0), 1))
    }

    private func update(translation t: CGSize, start: CGPoint, current: CGPoint) {
        guard let s = startSelection, imageFrame.width > 0, imageFrame.height > 0 else { return }
        let dx = t.width / imageFrame.width
        let dy = t.height / imageFrame.height

        switch dragKind {
        case .move:
            var r = s
            r.origin.x = min(max(0, s.minX + dx), 1 - s.width)
            r.origin.y = min(max(0, s.minY + dy), 1 - s.height)
            selection = r

        case .resize:
            var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
            if dragEdges.contains(.left) { minX = min(max(0, s.minX + dx), 1) }
            if dragEdges.contains(.right) { maxX = min(max(0, s.maxX + dx), 1) }
            if dragEdges.contains(.top) { minY = min(max(0, s.minY + dy), 1) }
            if dragEdges.contains(.bottom) { maxY = min(max(0, s.maxY + dy), 1) }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                               width: abs(maxX - minX), height: abs(maxY - minY))

        case .create:
            let a = normalized(start), b = normalized(current)
            selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                               width: abs(b.x - a.x), height: abs(b.y - a.y))

        case .none:
            break
        }
    }
}
