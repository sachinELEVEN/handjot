import SwiftUI

struct ContentView: View {
    //hello
    @StateObject private var manager = HandTrackingManager()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(previewLayer: manager.previewLayer)
                    .ignoresSafeArea()
                Canvas { context, size in
                    drawMonitorOutline(in: &context, size: size)
                    drawStrokes(in: &context, size: size)
                }//h
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
            VStack(spacing: 10) {
                Toggle("Auto-detect monitor", isOn: $manager.autoMonitorTrackingEnabled)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.vertical, 6)
                Toggle("Use ultra-wide camera", isOn: $manager.useUltraWideCamera)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.vertical, 2)
                    .onChange(of: manager.useUltraWideCamera) { _, newValue in
                        manager.applyCameraPreference(useUltraWide: newValue)
                    }
                HStack(spacing: 10) {
                    Button(cornerButtonTitle("Monitor TL", isSet: manager.calibrationProfile.monitorTopLeft != nil)) {
                        manager.captureCalibrationPoint(.monitorTopLeft)
                    }
                    .buttonStyle(CornerCaptureButtonStyle(isCaptured: manager.calibrationProfile.monitorTopLeft != nil))

                    Button(cornerButtonTitle("Monitor TR", isSet: manager.calibrationProfile.monitorTopRight != nil)) {
                        manager.captureCalibrationPoint(.monitorTopRight)
                    }
                    .buttonStyle(CornerCaptureButtonStyle(isCaptured: manager.calibrationProfile.monitorTopRight != nil))
                }
                HStack(spacing: 10) {
                    Button(cornerButtonTitle("Monitor BL", isSet: manager.calibrationProfile.monitorBottomLeft != nil)) {
                        manager.captureCalibrationPoint(.monitorBottomLeft)
                    }
                    .buttonStyle(CornerCaptureButtonStyle(isCaptured: manager.calibrationProfile.monitorBottomLeft != nil))

                    Button(cornerButtonTitle("Monitor BR", isSet: manager.calibrationProfile.monitorBottomRight != nil)) {
                        manager.captureCalibrationPoint(.monitorBottomRight)
                    }
                    .buttonStyle(CornerCaptureButtonStyle(isCaptured: manager.calibrationProfile.monitorBottomRight != nil))
                }
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

    private func drawMonitorOutline(in context: inout GraphicsContext, size: CGSize) {
        guard let corners = monitorCorners(in: size) else { return }
        var path = Path()
        path.move(to: corners[0])
        path.addLine(to: corners[1])
        path.addLine(to: corners[2])
        path.addLine(to: corners[3])
        path.closeSubpath()
        context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 3)
        context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1)
        context.fill(path, with: .color(.black.opacity(0.08)))
    }

    private func monitorCorners(in size: CGSize) -> [CGPoint]? {
        guard
            let tl = manager.calibrationProfile.monitorTopLeft,
            let tr = manager.calibrationProfile.monitorTopRight,
            let br = manager.calibrationProfile.monitorBottomRight,
            let bl = manager.calibrationProfile.monitorBottomLeft
        else { return nil }
        return [
            CGPoint(x: tl.x * size.width, y: tl.y * size.height),
            CGPoint(x: tr.x * size.width, y: tr.y * size.height),
            CGPoint(x: br.x * size.width, y: br.y * size.height),
            CGPoint(x: bl.x * size.width, y: bl.y * size.height)
        ]
    }

    private func cornerButtonTitle(_ title: String, isSet: Bool) -> String {
        isSet ? "\(title) ✓" : title
    }
}

private struct CornerCaptureButtonStyle: ButtonStyle {
    let isCaptured: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(isCaptured ? 0.65 : 0.28), lineWidth: 1)
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isCaptured {
            return Color.green.opacity(isPressed ? 0.65 : 0.45)
        }
        return Color.blue.opacity(isPressed ? 0.75 : 0.55)
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
