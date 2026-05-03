import SwiftUI

struct ContentView: View {
    @StateObject private var manager = HandTrackingManager()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(previewLayer: manager.previewLayer)
                    .ignoresSafeArea()
                Canvas { context, size in
                    drawDrawingBox(in: &context, size: size)
                    drawStrokes(in: &context, size: size)
                }
                .allowsHitTesting(false)
                if let coordinate = manager.latestCoordinate {
                    let hoverPoint: CGPoint = {
                        if let rect = drawingBoxRect(in: geometry.size) {
                            return CGPoint(x: rect.minX + coordinate.x * rect.width,
                                           y: rect.minY + coordinate.y * rect.height)
                        }
                        return CGPoint(x: coordinate.x * geometry.size.width,
                                       y: coordinate.y * geometry.size.height)
                    }()
                    Circle()
                        .strokeBorder(manager.currentDrawingColor.opacity(0.95), lineWidth: 3)
                        .background(Circle().fill(manager.currentDrawingColor.opacity(0.35)))
                        .frame(width: 42, height: 42)
                        .shadow(radius: 8)
                        .position(hoverPoint)
                        .overlay(
                            Circle()
                                .frame(width: 10, height: 10)
                                .foregroundColor(manager.currentDrawingColor)
                        )
                }
                if manager.manualMenuVisible {
                    ManualOptionsOverlay(manager: manager)
                        .frame(maxWidth: min(geometry.size.width * 0.75, 360))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.18)
                        .zIndex(1)
                }
                VStack {
                    Spacer()
                    overlay
                }
                .padding()
            }
            .onAppear {
                manager.startSession()
                manager.updateDrawingSurfaceSize(geometry.size)
            }
            .onDisappear { manager.stopSession() }
            .onChange(of: geometry.size) {
                manager.updateDrawingSurfaceSize($0)
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(manager.isDrawing ? "Drawing" : "Idle")
                        .font(.headline)
                        .foregroundColor(manager.isDrawing ? .green : .yellow)
                } icon: {
                    Image(systemName: manager.isDrawing ? "pencil.tip.crop.circle.fill" : "hand.raised.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                Spacer()
                if let coordinate = manager.latestCoordinate {
                    Text(coordinateLabel(for: coordinate))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundColor(.white)
                } else {
                    Text("No fingertip visible")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            Text(manager.calibrationMessage)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("Set Box Top-left") {
                    manager.captureCalibrationPoint(.topLeft)
                }
                .buttonStyle(.borderedProminent)

                Button("Set Box Bottom-right") {
                    manager.captureCalibrationPoint(.bottomRight)
                }
                .buttonStyle(.bordered)
            }
            if manager.isManualPaused {
                Label("Drawing paused", systemImage: "pause.fill")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let manualMessage = manager.manualActionMessage {
                Text(manualMessage)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func coordinateLabel(for coordinate: CoordinateMessage) -> String {
        let x = String(format: "%.2f", coordinate.x)
        let y = String(format: "%.2f", coordinate.y)
        let state = coordinate.drawing ? "drawing" : "idle"
        return "x: \(x) y: \(y) • \(state)"
    }

    private func drawStrokes(in context: inout GraphicsContext, size: CGSize) {
        let boxRect = drawingBoxRect(in: size)
        let allStrokes = manager.strokes + (manager.liveStroke.map { [$0] } ?? [])
        for stroke in allStrokes {
            guard stroke.points.count > 1 else { continue }
            var path = Path()
            let scaled: [CGPoint]
            if let boxRect {
                scaled = stroke.points.map { point in
                    CGPoint(x: boxRect.minX + point.x * boxRect.width,
                            y: boxRect.minY + point.y * boxRect.height)
                }
            } else {
                scaled = stroke.points.map { point in
                    CGPoint(x: point.x * size.width, y: point.y * size.height)
                }
            }
            path.move(to: scaled[0])
            for point in scaled.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(stroke.color.opacity(0.95)), lineWidth: 4)
            context.stroke(path, with: .color(.black.opacity(0.2)), lineWidth: 2)
        }
    }

    private func drawDrawingBox(in context: inout GraphicsContext, size: CGSize) {
        guard let rect = drawingBoxRect(in: size) else { return }
        let boxPath = Path(rect)
        context.stroke(boxPath, with: .color(.white.opacity(0.85)), lineWidth: 3)
        context.stroke(boxPath, with: .color(.black.opacity(0.35)), lineWidth: 1)
        context.fill(boxPath, with: .color(.black.opacity(0.08)))
    }

    private func drawingBoxRect(in size: CGSize) -> CGRect? {
        guard
            let tl = manager.calibrationProfile.topLeft,
            let br = manager.calibrationProfile.bottomRight
        else { return nil }

        let minX = min(tl.x, br.x) * size.width
        let minY = min(tl.y, br.y) * size.height
        let maxX = max(tl.x, br.x) * size.width
        let maxY = max(tl.y, br.y) * size.height

        let width = maxX - minX
        let height = maxY - minY
        guard width > 2, height > 2 else { return nil }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct ManualOptionsOverlay: View {
    @ObservedObject var manager: HandTrackingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(.white)
                Text("Gesture options")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            ForEach(manager.manualMenuOptions) { option in
                HStack(spacing: 12) {
                    Text("\(option.id)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .frame(width: 34, height: 34)
                        .background(manager.currentDrawingColor.opacity(0.9))
                        .clipShape(Circle())
                        .foregroundColor(.white)
                    Text(option.title)
                        .foregroundColor(.white)
                        .font(.body)
                }
            }

            Text("Raise the matching number of fingers to trigger the action.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.6), radius: 12, x: 0, y: 6)
    }
}
