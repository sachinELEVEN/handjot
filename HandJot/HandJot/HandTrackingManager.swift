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

struct CalibrationProfile {
    var topLeft: CGPoint?
    var bottomRight: CGPoint?

    func mappedPoint(from normalizedPoint: CGPoint) -> CGPoint {
        guard let tl = topLeft, let br = bottomRight else {
            return normalizedPoint
        }

        let width = br.x - tl.x
        let height = br.y - tl.y
        guard width > 0 && height > 0 else {
            return normalizedPoint
        }

        let x = (normalizedPoint.x - tl.x) / width
        let y = (normalizedPoint.y - tl.y) / height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

enum CalibrationAnchor {
    case topLeft
    case bottomRight
}

final class HandTrackingManager: NSObject, ObservableObject {
    @Published private(set) var strokes: [Stroke] = []
    @Published var latestCoordinate: CoordinateMessage?
    @Published private(set) var isDrawing: Bool = false
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

    override init() {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 1
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
        captureSession.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else {
            captureSession.commitConfiguration()
            calibrationMessage = "Camera unavailable"
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
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
        }

        if let connection = dataOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = true
        }

        previewLayer.videoGravity = .resizeAspectFill
        captureSession.commitConfiguration()
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

        switch anchor {
        case .topLeft:
            calibrationProfile.topLeft = point
            calibrationMessage = "Top-left anchor captured"
        case .bottomRight:
            calibrationProfile.bottomRight = point
            calibrationMessage = "Bottom-right anchor captured"
        }

        if calibrationProfile.topLeft != nil && calibrationProfile.bottomRight != nil {
            calibrationMessage = "Calibration ready"
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
        }
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

        if allowDrawing && movement >= movementStartThreshold {
            lastMovementTimestamp = now
            if !drawingState {
                startStroke(at: smoothed)
            }
        }

        if drawingState {
            if allowDrawing {
                appendPoint(smoothed)
                if let lastMove = lastMovementTimestamp, now.timeIntervalSince(lastMove) >= stopTimeout {
                    finalizeStroke()
                }
            } else {
                finalizeStroke()
            }
        }

        let calibrated = calibrationProfile.mappedPoint(from: smoothed)
        let message = CoordinateMessage(x: calibrated.x, y: calibrated.y, drawing: drawingState, timestamp: now)
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
        let strokesPayload = strokes.compactMap { $0.serializable() }
        let livePayload = drawingStroke?.serializable()
        let optionsPayload = manualMenuVisible ? manualMenuItems : nil
        let message = RemoteDrawingMessage(type: type,
                                           timestamp: Date(),
                                           strokes: strokesPayload,
                                           liveStroke: livePayload,
                                           menuVisible: manualMenuVisible,
                                           menuOptions: optionsPayload,
                                           canvasSize: drawingSurfaceSize)
        remoteClient.send(message)
    }

    private func detectGesture(from observation: VNHumanHandPoseObservation) {
        let extendedCount = countExtendedFingers(from: observation)
        if manualMenuVisible {
            evaluateManualSelection(for: extendedCount)
        } else if manualMenuCooldownUntil == nil || manualMenuCooldownUntil! <= Date() {
            updateFistCounter(for: extendedCount)
        }
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
            try requestHandler.perform([handPoseRequest])
        } catch {
            handleNoObservation()
            return
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
