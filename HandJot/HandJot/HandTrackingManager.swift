import AVFoundation
import Combine
import Foundation
import SwiftUI
import Vision

struct CoordinateMessage: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let drawing: Bool
    let timestamp: Date
}

struct Stroke: Identifiable {
    let id = UUID()
    var points: [CGPoint] = []
    let color: Color
}

private struct Homography {
    // Row-major 3x3 matrix.
    let h: [Double]

    func apply(to point: CGPoint) -> CGPoint? {
        guard h.count == 9 else { return nil }
        let x = Double(point.x)
        let y = Double(point.y)
        let denom = h[6] * x + h[7] * y + h[8]
        guard abs(denom) > 1e-9 else { return nil }
        let nx = (h[0] * x + h[1] * y + h[2]) / denom
        let ny = (h[3] * x + h[4] * y + h[5]) / denom
        return CGPoint(x: nx, y: ny)
    }
}

private func solveLinearSystem(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
    var m = a
    var rhs = b

    for col in 0..<n {
        var pivotRow = col
        var pivotValue = abs(m[col][col])
        for row in (col + 1)..<n {
            let v = abs(m[row][col])
            if v > pivotValue {
                pivotValue = v
                pivotRow = row
            }
        }
        if pivotValue < 1e-12 { return nil }
        if pivotRow != col {
            m.swapAt(pivotRow, col)
            rhs.swapAt(pivotRow, col)
        }

        let pivot = m[col][col]
        for j in col..<n { m[col][j] /= pivot }
        rhs[col] /= pivot

        for row in 0..<n where row != col {
            let factor = m[row][col]
            if abs(factor) < 1e-12 { continue }
            for j in col..<n { m[row][j] -= factor * m[col][j] }
            rhs[row] -= factor * rhs[col]
        }
    }

    return rhs
}

private func computeHomography(from src: [CGPoint], to dst: [CGPoint]) -> Homography? {
    guard src.count == 4, dst.count == 4 else { return nil }

    // Solve for h11..h32 with h33=1
    var a: [[Double]] = Array(repeating: Array(repeating: 0, count: 8), count: 8)
    var b: [Double] = Array(repeating: 0, count: 8)

    for i in 0..<4 {
        let x = Double(src[i].x)
        let y = Double(src[i].y)
        let u = Double(dst[i].x)
        let v = Double(dst[i].y)

        let r0 = i * 2
        let r1 = r0 + 1

        a[r0][0] = x
        a[r0][1] = y
        a[r0][2] = 1
        a[r0][6] = -u * x
        a[r0][7] = -u * y
        b[r0] = u

        a[r1][3] = x
        a[r1][4] = y
        a[r1][5] = 1
        a[r1][6] = -v * x
        a[r1][7] = -v * y
        b[r1] = v
    }

    guard let x = solveLinearSystem(a, b) else { return nil }
    let h: [Double] = [
        x[0], x[1], x[2],
        x[3], x[4], x[5],
        x[6], x[7], 1
    ]
    return Homography(h: h)
}

struct CalibrationProfile {
    // Monitor corners in camera-normalized coordinates (0..1) in clockwise order.
    var monitorTopLeft: CGPoint?
    var monitorTopRight: CGPoint?
    var monitorBottomRight: CGPoint?
    var monitorBottomLeft: CGPoint?

    // Optional drawing rectangle inside the monitor, stored in monitor-normalized coordinates (0..1).//
    var drawAreaTopLeft: CGPoint?
    var drawAreaBottomRight: CGPoint?
    //

    var isMonitorReady: Bool {
        monitorTopLeft != nil &&
        monitorTopRight != nil &&
        monitorBottomRight != nil &&
        monitorBottomLeft != nil
    }

    var isDrawAreaReady: Bool {
        drawAreaTopLeft != nil && drawAreaBottomRight != nil
    }

    func monitorCornersArray() -> [CGPoint]? {
        guard
            let tl = monitorTopLeft,
            let tr = monitorTopRight,
            let br = monitorBottomRight,
            let bl = monitorBottomLeft
        else { return nil }
        return [tl, tr, br, bl]
    }

    func drawAreaBoxPayload() -> DrawingBox? {
        guard let tl = drawAreaTopLeft, let br = drawAreaBottomRight else { return nil }
        let minX = min(tl.x, br.x)
        let minY = min(tl.y, br.y)
        let maxX = max(tl.x, br.x)
        let maxY = max(tl.y, br.y)
        return DrawingBox(
            topLeft: SerializablePoint(x: minX, y: minY),
            bottomRight: SerializablePoint(x: maxX, y: maxY)
        )
    }
}

enum CalibrationAnchor {
    case monitorTopLeft
    case monitorTopRight
    case monitorBottomRight
    case monitorBottomLeft
    case drawAreaTopLeft
    case drawAreaBottomRight
}

final class HandTrackingManager: NSObject, ObservableObject {
    @Published private(set) var strokes: [Stroke] = []
    @Published var latestCoordinate: CoordinateMessage?
    @Published private(set) var isDrawing: Bool = false
    @Published private(set) var isPenDown: Bool = false
    @Published private(set) var manualMenuVisible = false
    @Published private(set) var manualActionMessage: String?
    @Published private(set) var isManualPaused: Bool = false
    @Published private(set) var calibrationProfile = CalibrationProfile()
    @Published var calibrationMessage: String = "Move your finger on screen to calibrate"
    @Published var currentDrawingColor: Color = .white

    var liveStroke: Stroke? {
        drawingStroke
    }

    private(set) var previewLayer: AVCaptureVideoPreviewLayer

    private let captureSession = AVCaptureSession()
    private let processingQueue = DispatchQueue(label: "handjot.hand-tracking")
    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let rectangleRequest: VNDetectRectanglesRequest
    private var lastSmoothedPoint: CGPoint?
    private var drawingStroke: Stroke?
    private var drawingState: Bool = false
    private var lastMovementTimestamp: Date?
    private var lastMovementDelta: CGFloat = 0
    private var latestNormalizedPoint: CGPoint?
    private var allowDrawing: Bool = true
    private let palette: [Color] = [.white, .mint, .cyan, .pink, .orange]
    private var colorIndex: Int = 0
    private var fistFrameCount: Int = 0
    private let fistFrameThreshold: Int = 20
    private var selectionStableCount: Int = 0
    private var lastSelectionCount: Int?
    private var manualMenuCooldownUntil: Date?
    private let selectionFrameThreshold: Int = 6
    private let manualMenuCooldown: TimeInterval = 1.2
    private var messageWorkItem: DispatchWorkItem?
    private var drawingSurfaceSize: CanvasSize?
    @Published var autoMonitorTrackingEnabled: Bool = true
    private let monitorCornerSmoothing: CGFloat = 0.22
    private var penDownState: Bool = false
    private let penPinchThreshold: CGFloat = 0.35

    private let remoteClient = RemoteDrawingClient()
    private let manualMenuItems: [ManualMenuItem] = [
        .init(id: 1, title: "Change color"),
        .init(id: 2, title: "New drawing space"),
        .init(id: 3, title: "Undo"),
        .init(id: 5, title: "Drawing/Pause toggle")
    ]

    var manualMenuOptions: [ManualMenuItem] {
        manualMenuItems
    }

    private let movementStartThreshold: CGFloat = 0.0
    private let stopTimeout: TimeInterval = 0.25
    private let smoothingFactor: CGFloat = 0.45
    private let fistMovementResetThreshold: CGFloat = 100//make it big because we dont need it
    private var currentModeDrawingFromOptionMenu = true;
    @Published var useUltraWideCamera: Bool = false
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?

    override init() {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 1
        rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 1
        rectangleRequest.minimumConfidence = 0.55
        rectangleRequest.minimumAspectRatio = 0.35
        rectangleRequest.quadratureTolerance = 30
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        super.init()
        configureCaptureSession()
        startSession()
    }

    deinit {
        stopSession()
    }

    private func configureCaptureSession() {
        captureSession.beginConfiguration()
        // Some devices (especially ultra-wide) can be picky about presets.
        // Prefer `.high`, otherwise fall back to a commonly supported HD preset.
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.high) ? .high : .hd1280x720

        if let videoInput {
            captureSession.removeInput(videoInput)
            self.videoInput = nil
        }
        if let videoOutput {
            captureSession.removeOutput(videoOutput)
            self.videoOutput = nil
        }

        let preferredDevice: AVCaptureDevice? = {
            if useUltraWideCamera {
                return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }()

        let fallbackDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let device = preferredDevice ?? fallbackDevice
        else {
            captureSession.commitConfiguration()
            calibrationMessage = "Camera unavailable"
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                videoInput = input
            }
        } catch {
            calibrationMessage = "Camera input failed: \(error.localizedDescription)"
        }

        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if captureSession.canAddOutput(dataOutput) {
            captureSession.addOutput(dataOutput)
            videoOutput = dataOutput
        }

        if let connection = dataOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = true
        }

        previewLayer.videoGravity = .resizeAspectFill
        if let previewConnection = previewLayer.connection, previewConnection.isVideoOrientationSupported {
            previewConnection.videoOrientation = .portrait
        }
        captureSession.commitConfiguration()
    }

    func applyCameraPreference(useUltraWide: Bool) {
        guard useUltraWideCamera != useUltraWide else { return }
        useUltraWideCamera = useUltraWide
        processingQueue.async { [weak self] in
            guard let self else { return }
            let wasRunning = self.captureSession.isRunning
            if wasRunning { self.captureSession.stopRunning() }
            self.configureCaptureSession()
            if wasRunning { self.captureSession.startRunning() }
        }
        DispatchQueue.main.async {
            self.calibrationMessage = useUltraWide ? "Switched to ultra-wide camera" : "Switched to wide camera"
        }
    }

    func startSession() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stopSession() {
        processingQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    func captureCalibrationPoint(_ anchor: CalibrationAnchor) -> Bool {
        guard let point = latestNormalizedPoint else {
            calibrationMessage = "Point unavailable. Move your finger to capture"
            return false
        }

        // New anchors change the coordinate system; discard existing strokes.
        drawingStroke = nil
        drawingState = false
        lastMovementTimestamp = nil
        lastSmoothedPoint = nil
        DispatchQueue.main.async {
            self.strokes.removeAll()
            self.isDrawing = false
        }

        switch anchor {
        case .monitorTopLeft:
            calibrationProfile.monitorTopLeft = point
        case .monitorTopRight:
            calibrationProfile.monitorTopRight = point
        case .monitorBottomRight:
            calibrationProfile.monitorBottomRight = point
        case .monitorBottomLeft:
            calibrationProfile.monitorBottomLeft = point
        case .drawAreaTopLeft:
            guard let homography = monitorHomography(), let p = homography.apply(to: point) else {
                calibrationMessage = "Set all 4 monitor corners first"
                DispatchQueue.main.async { self.publishRemoteDrawingState() }
                return false
            }
            calibrationProfile.drawAreaTopLeft = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        case .drawAreaBottomRight:
            guard let homography = monitorHomography(), let p = homography.apply(to: point) else {
                calibrationMessage = "Set all 4 monitor corners first"
                DispatchQueue.main.async { self.publishRemoteDrawingState() }
                return false
            }
            calibrationProfile.drawAreaBottomRight = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        }

        if !calibrationProfile.isMonitorReady {
            calibrationMessage = "Set all 4 monitor corners to start drawing"
        } else if !calibrationProfile.isDrawAreaReady {
            calibrationMessage = "Monitor ready — set draw area TL + BR (optional)"
        } else {
            calibrationMessage = "Draw area ready — start drawing"
        }

        DispatchQueue.main.async {
            self.publishRemoteDrawingState()
        }

        return true
    }

    func updateDrawingSurfaceSize(_ size: CGSize) {
        drawingSurfaceSize = CanvasSize(width: Double(size.width), height: Double(size.height))
    }

    private func handleNoObservation() {
        lastSmoothedPoint = nil
        latestNormalizedPoint = nil
        lastMovementDelta = 0
        lastMovementTimestamp = nil
        if drawingState {
            finalizeStroke()
        }
        DispatchQueue.main.async {
            self.latestCoordinate = nil
            self.isDrawing = false
            self.isPenDown = false
        }
        penDownState = false
    }

    private func smoothPoint(_ current: CGPoint) -> CGPoint {
        guard let previous = lastSmoothedPoint else {
            lastSmoothedPoint = current
            return current
        }

        let blended = CGPoint(x: previous.x * (1 - smoothingFactor) + current.x * smoothingFactor,
                              y: previous.y * (1 - smoothingFactor) + current.y * smoothingFactor)
        lastSmoothedPoint = blended
        return blended
    }

    private func processNormalizedPoint(_ point: CGPoint) {
        let now = Date()
        let previousSmoothed = lastSmoothedPoint
        let smoothed = smoothPoint(point)
        latestNormalizedPoint = smoothed
        let movement = movementDistance(from: smoothed, to: previousSmoothed)
        lastMovementDelta = movement

        if movement >= fistMovementResetThreshold {
            fistFrameCount = 0
        }

        let drawingEnabled = allowDrawing && calibrationProfile.isMonitorReady && penDownState
        let isInsideMonitor = isPointInsideMonitor(smoothed)
        let isInsideDrawArea = isPointInsideDrawArea(smoothed)

        if drawingEnabled && isInsideMonitor && isInsideDrawArea && movement >= movementStartThreshold {
            lastMovementTimestamp = now
            if !drawingState {
                startStroke(at: smoothed)
            }
        }

        if drawingState {
            if drawingEnabled {
                if isInsideMonitor && isInsideDrawArea {
                    appendPoint(smoothed)
                } else {
                    finalizeStroke()
                }
                if let lastMove = lastMovementTimestamp, now.timeIntervalSince(lastMove) >= stopTimeout {
                    finalizeStroke()
                }
            } else {
                finalizeStroke()
            }
        }

        let message = CoordinateMessage(x: smoothed.x, y: smoothed.y, drawing: drawingState, timestamp: now)
        DispatchQueue.main.async {
            self.latestCoordinate = message
            self.isDrawing = self.drawingState
            if self.drawingState || self.manualMenuVisible {
                self.publishRemoteDrawingState()
            }
        }
    }

    private func movementDistance(from current: CGPoint, to previous: CGPoint?) -> CGFloat {
        guard let previous = previous else { return 0 }
        return hypot(current.x - previous.x, current.y - previous.y)
    }

    private func startStroke(at point: CGPoint) {
        drawingState = true
        drawingStroke = Stroke(points: [point], color: currentDrawingColor)
    }

    private func appendPoint(_ point: CGPoint) {
        guard drawingState else { return }
        if drawingStroke == nil {
            drawingStroke = Stroke(points: [], color: currentDrawingColor)
        }
        drawingStroke?.points.append(point)
    }

    private func finalizeStroke() {
        drawingState = false
        let strokeToAppend = drawingStroke
        drawingStroke = nil
        lastMovementTimestamp = nil
        DispatchQueue.main.async {
            if let stroke = strokeToAppend, stroke.points.count > 1 {
                self.strokes.append(stroke)
            }
            self.isDrawing = false
            self.publishRemoteDrawingState()
        }
    }

    private func showManualMenu() {
        guard !manualMenuVisible else { return }
        allowDrawing = false
        finalizeStroke()
        DispatchQueue.main.async {
            self.manualMenuVisible = true
            self.publishRemoteDrawingState(type: .menu)
        }
        flashManualActionMessage("Menu ready — show 1-5 fingers to choose an action")
    }

    private func hideManualMenu() {
        guard manualMenuVisible else { return }
        DispatchQueue.main.async {
            self.manualMenuVisible = false
            self.publishRemoteDrawingState(type: .menu)
        }
        manualMenuCooldownUntil = Date().addingTimeInterval(manualMenuCooldown)
        selectionStableCount = 0
        lastSelectionCount = nil
        fistFrameCount = 0
        allowDrawing = !isManualPaused
    }

    private func evaluateManualSelection(for count: Int) {
        guard (1...5).contains(count) else { return }
        if lastSelectionCount != count {
            lastSelectionCount = count
            selectionStableCount = 1
            return
        }
        selectionStableCount += 1
        if selectionStableCount >= selectionFrameThreshold {
            
            lastSelectionCount = nil
            selectionStableCount = 0
           performManualOption(count)
        }
    }

    private func performManualOption(_ number: Int) {
        switch number {
        case 1:
            hideManualMenu()
            cycleColor()
            
        case 2:
            hideManualMenu()
            clearDrawing()
            
        case 3:
            hideManualMenu()
            undoLastStroke()
            
//        case 4: //4 fingers are now used for showing the option menu to the user as its more reliable
//            enterDrawingMode()
        case 5:
            hideManualMenu()
            currentModeDrawingFromOptionMenu ? pauseDrawing() : enterDrawingMode()
            
//            pauseDrawing()
        default:
            break
        }
    }

    private func cycleColor() {
        colorIndex = (colorIndex + 1) % palette.count
        let nextColor = palette[colorIndex]
        DispatchQueue.main.async {
            self.currentDrawingColor = nextColor
        }
        flashManualActionMessage("Color changed")
    }

    private func clearDrawing() {
        drawingStroke = nil
        DispatchQueue.main.async {
            self.strokes.removeAll()
            self.publishRemoteDrawingState()
        }
        flashManualActionMessage("Cleared drawing")
    }

    private func undoLastStroke() {
        DispatchQueue.main.async {
            if !self.strokes.isEmpty {
                self.strokes.removeLast()
                self.flashManualActionMessage("Undid last stroke")
                self.publishRemoteDrawingState()
            } else {
                self.flashManualActionMessage("Nothing to undo yet")
            }
        }
    }

    private func enterDrawingMode() {
        allowDrawing = true
        currentModeDrawingFromOptionMenu = true
        DispatchQueue.main.async {
            self.isManualPaused = false
        }
        flashManualActionMessage("Drawing mode enabled")
    }

    private func pauseDrawing() {
        allowDrawing = false
        currentModeDrawingFromOptionMenu = false
        DispatchQueue.main.async {
            self.isManualPaused = true
        }
        flashManualActionMessage("Drawing paused — reopen menu to resume")
    }

    private func flashManualActionMessage(_ text: String) {
        DispatchQueue.main.async {
            self.manualActionMessage = text
        }
        messageWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.manualActionMessage == text else { return }
                self.manualActionMessage = nil
            }
        }
        messageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func publishRemoteDrawingState(type: RemoteDrawingMessageType = .strokes) {
        let homography = monitorHomography()

        let strokesPayload: [SerializableStroke] = strokes.compactMap { stroke in
            guard let serializableColor = SerializableColor(color: stroke.color) else { return nil }
            let mappedPoints: [SerializablePoint] = stroke.points.compactMap { point in
                guard let p = homography?.apply(to: point) else { return nil }
                return SerializablePoint(x: p.x, y: p.y)
            }
            guard mappedPoints.count > 1 else { return nil }
            return SerializableStroke(id: stroke.id, points: mappedPoints, color: serializableColor)
        }

        let livePayload: SerializableStroke? = {
            guard let stroke = drawingStroke else { return nil }
            guard let serializableColor = SerializableColor(color: stroke.color) else { return nil }
            let mappedPoints: [SerializablePoint] = stroke.points.compactMap { point in
                guard let p = homography?.apply(to: point) else { return nil }
                return SerializablePoint(x: p.x, y: p.y)
            }
            guard mappedPoints.count > 1 else { return nil }
            return SerializableStroke(id: stroke.id, points: mappedPoints, color: serializableColor)
        }()
        let optionsPayload = manualMenuVisible ? manualMenuItems : nil
//
        let monitorQuadPayload: MonitorQuad? = {
            guard let corners = calibrationProfile.monitorCornersArray() else { return nil }
            // When we're in monitor space, the monitor plane becomes the unit square.
            if homography != nil {
                return MonitorQuad(
                    topLeft: SerializablePoint(x: 0, y: 0),
                    topRight: SerializablePoint(x: 1, y: 0),
                    bottomRight: SerializablePoint(x: 1, y: 1),
                    bottomLeft: SerializablePoint(x: 0, y: 1)
                )
            }

            // Otherwise provide the camera-space quad so the web view can still visualize it.
            return MonitorQuad(
                topLeft: SerializablePoint(x: corners[0].x, y: corners[0].y),
                topRight: SerializablePoint(x: corners[1].x, y: corners[1].y),
                bottomRight: SerializablePoint(x: corners[2].x, y: corners[2].y),
                bottomLeft: SerializablePoint(x: corners[3].x, y: corners[3].y)
            )
        }()

        let message = RemoteDrawingMessage(type: type,
                                           timestamp: Date(),
                                           strokes: strokesPayload,
                                           liveStroke: livePayload,
                                           menuVisible: manualMenuVisible,
                                           menuOptions: optionsPayload,
                                           canvasSize: drawingSurfaceSize,
                                           drawingBox: calibrationProfile.drawAreaBoxPayload(),
                                           coordinateSpace: homography == nil ? nil : "monitor",
                                           monitorQuad: monitorQuadPayload)
        remoteClient.send(message)
    }

    private func monitorHomography() -> Homography? {
        guard let corners = calibrationProfile.monitorCornersArray() else { return nil }
        let dst: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1)
        ]
        return computeHomography(from: corners, to: dst)
    }

    private func isPointInsideMonitor(_ point: CGPoint) -> Bool {
        guard let corners = calibrationProfile.monitorCornersArray() else { return true }
        // corners: TL, TR, BR, BL; split quad into two triangles.
        return pointInTriangle(point, corners[0], corners[1], corners[2]) ||
            pointInTriangle(point, corners[0], corners[2], corners[3])
    }

    private func isPointInsideDrawArea(_ point: CGPoint) -> Bool {
        guard calibrationProfile.isDrawAreaReady else { return true }
        guard let homography = monitorHomography(), let p = homography.apply(to: point) else { return true }
        guard let tl = calibrationProfile.drawAreaTopLeft, let br = calibrationProfile.drawAreaBottomRight else { return true }
        let minX = min(tl.x, br.x)
        let minY = min(tl.y, br.y)
        let maxX = max(tl.x, br.x)
        let maxY = max(tl.y, br.y)
        return p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    private func pointInTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        func sign(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = sign(p, a, b)
        let d2 = sign(p, b, c)
        let d3 = sign(p, c, a)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNeg && hasPos)
    }

    private func detectGesture(from observation: VNHumanHandPoseObservation) {
        let penDownNow = computePenDown(from: observation)
        penDownState = penDownNow
        DispatchQueue.main.async {
            self.isPenDown = penDownNow
        }

        let extendedCount = countExtendedFingers(from: observation)
        if manualMenuVisible {
            evaluateManualSelection(for: extendedCount)
        } else if manualMenuCooldownUntil == nil || manualMenuCooldownUntil! <= Date() {
            updateFistCounter(for: extendedCount)
        }
    }

    private func computePenDown(from observation: VNHumanHandPoseObservation) -> Bool {
        func point(_ name: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            guard let p = try? observation.recognizedPoint(name), p.confidence > 0.35 else {
                return nil
            }
            return p
        }

        guard
            let wrist = point(.wrist),
            let indexMCP = point(.indexMCP),
            let thumbTip = point(.thumbTip),
            let indexTip = point(.indexTip)
        else { return false }

        // Normalize pinch distance by palm size so it scales across camera distances.
        let palmSize = hypot(indexMCP.location.x - wrist.location.x,
                             indexMCP.location.y - wrist.location.y)
        guard palmSize > 1e-6 else { return false }

        let pinchDist = hypot(indexTip.location.x - thumbTip.location.x,
                              indexTip.location.y - thumbTip.location.y)

        // Heuristic: if thumb + index are close (like holding a pen), treat as "pen down".
        return pinchDist < palmSize * penPinchThreshold
    }

    private func updateFistCounter(for extendedCount: Int) {
        //we dont look for first but look for 4 fingers for showing the option menu
        if extendedCount == 4 {
            fistFrameCount += 1
            if fistFrameCount >= fistFrameThreshold {
                fistFrameCount = 0
                showManualMenu()
            }
        } else {
            fistFrameCount = 0
        }
    }

    private func countExtendedFingers(from observation: VNHumanHandPoseObservation) -> Int {

        func point(_ name: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            guard let p = try? observation.recognizedPoint(name), p.confidence > 0.5 else {
                return nil
            }
            return p
        }

        guard
            let wrist = point(.wrist),
            let indexMCP = point(.indexMCP),
            let middleMCP = point(.middleMCP)
        else {
            return 0
        }

        // Palm size used for normalization
        let palmSize = hypot(indexMCP.location.x - wrist.location.x,
                             indexMCP.location.y - wrist.location.y)

        var extended = 0

        // Helper to compute angle at a joint
        func angle(a: CGPoint, b: CGPoint, c: CGPoint) -> CGFloat {
            let ab = CGVector(dx: a.x - b.x, dy: a.y - b.y)
            let cb = CGVector(dx: c.x - b.x, dy: c.y - b.y)

            let dot = ab.dx * cb.dx + ab.dy * cb.dy
            let magAB = sqrt(ab.dx * ab.dx + ab.dy * ab.dy)
            let magCB = sqrt(cb.dx * cb.dx + cb.dy * cb.dy)

            guard magAB > 0, magCB > 0 else { return 0 }

            let cosAngle = dot / (magAB * magCB)
            return acos(max(-1, min(1, cosAngle))) * 180 / .pi
        }

        // Finger detection using joint angles
        func fingerExtended(mcp: VNHumanHandPoseObservation.JointName,
                            pip: VNHumanHandPoseObservation.JointName,
                            tip: VNHumanHandPoseObservation.JointName) -> Bool {

            guard
                let mcpP = point(mcp),
                let pipP = point(pip),
                let tipP = point(tip)
            else { return false }

            let a = CGPoint(x: mcpP.location.x, y: mcpP.location.y)
            let b = CGPoint(x: pipP.location.x, y: pipP.location.y)
            let c = CGPoint(x: tipP.location.x, y: tipP.location.y)

            let jointAngle = angle(a: a, b: b, c: c)

            // Straight finger ≈ 160°+
            if jointAngle > 160 {
                let tipDist = hypot(tipP.location.x - wrist.location.x,
                                    tipP.location.y - wrist.location.y)

                // Ensure finger actually extends away from palm
                return tipDist > palmSize * 0.7
            }

            return false
        }

        // Index
        if fingerExtended(mcp: .indexMCP, pip: .indexPIP, tip: .indexTip) {
            extended += 1
        }

        // Middle
        if fingerExtended(mcp: .middleMCP, pip: .middlePIP, tip: .middleTip) {
            extended += 1
        }

        // Ring
        if fingerExtended(mcp: .ringMCP, pip: .ringPIP, tip: .ringTip) {
            extended += 1
        }

        // Little
        if fingerExtended(mcp: .littleMCP, pip: .littlePIP, tip: .littleTip) {
            extended += 1
        }

        // Thumb (different logic)
        if let thumbTip = point(.thumbTip),
           let thumbIP = point(.thumbIP),
           let thumbCMC = point(.thumbCMC) {

            let tip = thumbTip.location
            let ip = thumbIP.location
            let cmc = thumbCMC.location

            let thumbExtension = hypot(tip.x - cmc.x, tip.y - cmc.y)
            let thumbFold = hypot(ip.x - cmc.x, ip.y - cmc.y)

            if thumbExtension > thumbFold * 1.2 {
                extended += 1
            }
        }

        return extended
    }}

extension HandTrackingManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            handleNoObservation()
            return
        }

        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try requestHandler.perform([handPoseRequest, rectangleRequest])
        } catch {
            handleNoObservation()
            return
        }

        if autoMonitorTrackingEnabled, let rect = rectangleRequest.results?.first as? VNRectangleObservation {
            updateMonitorCorners(from: rect)
        }

        guard let observation = handPoseRequest.results?.first else {
            handleNoObservation()
            return
        }

        do {
            let indexTip = try observation.recognizedPoint(.indexTip)
            guard indexTip.confidence >= 0.35 else {
                handleNoObservation()
                return
            }

            let normalized = CGPoint(x: 1 - indexTip.location.x, y: 1 - indexTip.location.y)
            detectGesture(from: observation)
            processNormalizedPoint(normalized)
        } catch {
            handleNoObservation()
        }
    }
}

extension HandTrackingManager {
    private func smoothCorner(_ current: CGPoint?, target: CGPoint) -> CGPoint {
        guard let current else { return target }
        return CGPoint(
            x: current.x * (1 - monitorCornerSmoothing) + target.x * monitorCornerSmoothing,
            y: current.y * (1 - monitorCornerSmoothing) + target.y * monitorCornerSmoothing
        )
    }

    private func updateMonitorCorners(from observation: VNRectangleObservation) {
        // Vision coordinates -> our normalized coords (same transform as fingertip)
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: 1 - p.x, y: 1 - p.y)
        }

        let tl = map(observation.topLeft)
        let tr = map(observation.topRight)
        let br = map(observation.bottomRight)
        let bl = map(observation.bottomLeft)

        DispatchQueue.main.async {
            self.calibrationProfile.monitorTopLeft = self.smoothCorner(self.calibrationProfile.monitorTopLeft, target: tl)
            self.calibrationProfile.monitorTopRight = self.smoothCorner(self.calibrationProfile.monitorTopRight, target: tr)
            self.calibrationProfile.monitorBottomRight = self.smoothCorner(self.calibrationProfile.monitorBottomRight, target: br)
            self.calibrationProfile.monitorBottomLeft = self.smoothCorner(self.calibrationProfile.monitorBottomLeft, target: bl)
        }
    }
}
