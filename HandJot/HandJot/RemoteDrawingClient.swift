import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

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

final class RemoteDrawingClient {
    private let endpoint: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "handjot.remote-stream")

    init(endpoint: URL? = nil, session: URLSession = .shared) {
        if let endpoint = endpoint {
            self.endpoint = endpoint
        } else {
            self.endpoint = URL(string: "https://example.com/api/drawing")!
        }
        self.session = session
    }

    func send(_ message: RemoteDrawingMessage) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var request = URLRequest(url: self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let data = try? JSONEncoder().encode(message) else { return }
            request.httpBody = data
            let task = self.session.dataTask(with: request) { _, _, error in
                if let error = error {
                    print("RemoteDrawingClient send error: \(error.localizedDescription)")
                }
            }
            task.resume()
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
