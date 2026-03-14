import Foundation

import SwiftUI
//#if canImport(UIKit)
import UIKit
//#endif

struct SerializablePoint: Codable {
    let x: CGFloat
    let y: CGFloat
}

struct SerializableColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(color: Color) {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        self.red = Double(red)
        self.green = Double(green)
        self.blue = Double(blue)
        self.alpha = Double(alpha)
        #else
        return nil
        #endif
    }
}

struct SerializableStroke: Codable {
    let id: UUID
    let points: [SerializablePoint]
    let color: SerializableColor
}

enum RemoteDrawingMessageType: String, Codable {
    case strokes
    case menu
}

struct RemoteDrawingMessage: Codable {
    let type: RemoteDrawingMessageType
    let timestamp: Date
    let strokes: [SerializableStroke]
    let liveStroke: SerializableStroke?
    let menuVisible: Bool?
    let menuOptions: [ManualMenuItem]?
}
private struct WebSocketEnvelope: Codable {
    let action: String
    let payload: RemoteDrawingMessage?
}

final class RemoteDrawingClient {
    private let endpoint: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "handjot.remote-ws")
    private var webSocketTask: URLSessionWebSocketTask?
    private let reconnectInterval: TimeInterval = 2
    private var reconnectWorkItem: DispatchWorkItem?

    init(endpoint: URL? = nil, session: URLSession = .shared) {
        if let endpoint = endpoint {
            self.endpoint = endpoint
        } else {
            self.endpoint = URL(string: "wss://e0a0-38-254-176-186.ngrok-free.app/ws")!
        }
        self.session = session
        connect()
    }

    private func connect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = self.session.webSocketTask(with: self.endpoint)
            self.webSocketTask?.resume()
            self.listen()
        }
    }

    private func listen() {
        queue.async { [weak self] in
            guard let self = self, let task = self.webSocketTask else { return }
            task.receive { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect()
                case .success:
                    self.listen()
                @unknown default:
                    self.listen()
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + reconnectInterval, execute: workItem)
    }

    func send(_ message: RemoteDrawingMessage) {
        queue.async { [weak self] in
            guard let self = self, let task = self.webSocketTask else { return }
            let envelope = WebSocketEnvelope(action: "publish", payload: message)
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            task.send(.data(data)) { [weak self] error in
                if let error = error {
                    print("RemoteDrawingClient ws send error: \(error.localizedDescription)")
                    self?.scheduleReconnect()
                }
            }
        }
    }
    
}

extension Stroke {
    func serializable() -> SerializableStroke? {
        guard let serializableColor = SerializableColor(color: color) else { return nil }
        let payload = points.map { SerializablePoint(x: $0.x, y: $0.y) }
        return SerializableStroke(id: id, points: payload, color: serializableColor)
    }
}
