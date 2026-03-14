import SwiftUI

struct ContentView: View {
    @StateObject private var manager = HandTrackingManager()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(previewLayer: manager.previewLayer)
                    .ignoresSafeArea()
                Canvas { context, size in
                    drawStrokes(in: &context, size: size)
                }
                .allowsHitTesting(false)
                if let coordinate = manager.latestCoordinate {
                    let hoverPoint = CGPoint(x: coordinate.x * geometry.size.width,
                                             y: coordinate.y * geometry.size.height)
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
                    VStack {
                        ManualOptionsOverlay(manager: manager)
                            .padding(.top, 24)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(1)
                }
                VStack {
                    Spacer()
                    overlay
                }
                .padding()
            }
            .onAppear { manager.startSession() }
            .onDisappear { manager.stopSession() }
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
                Button("Capture Top-left") {
                    manager.captureCalibrationPoint(.topLeft)
                }
                .buttonStyle(.borderedProminent)

                Button("Capture Bottom-right") {
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
        let allStrokes = manager.strokes + (manager.liveStroke.map { [$0] } ?? [])
        for stroke in allStrokes {
            guard stroke.points.count > 1 else { continue }
            var path = Path()
            let scaled = stroke.points.map { point in
                CGPoint(x: point.x * size.width, y: point.y * size.height)
            }
            path.move(to: scaled[0])
            for point in scaled.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(stroke.color.opacity(0.95)), lineWidth: 4)
            context.stroke(path, with: .color(.black.opacity(0.2)), lineWidth: 2)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct ManualOptionsOverlay: View {
    @ObservedObject var manager: HandTrackingManager

    private let options: [(Int, String)] = [
        (1, "Change color"),
        (2, "New drawing space"),
        (3, "Undo"),
       // (4, "Drawing mode"),
        (5, "Drawing/Pause toggle")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(.white)
                Text("Gesture options")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            ForEach(options, id: \.0) { option in
                HStack(spacing: 12) {
                    Text("\(option.0)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .frame(width: 34, height: 34)
                        .background(manager.currentDrawingColor.opacity(0.9))
                        .clipShape(Circle())
                        .foregroundColor(.white)
                    Text(option.1)
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
