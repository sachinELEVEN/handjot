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
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.red = Double(red)
            self.green = Double(green)
            self.blue = Double(blue)
            self.alpha = Double(alpha)
            return
        }

        var white: CGFloat = 0
        if uiColor.getWhite(&white, alpha: &alpha) {
            self.red = Double(white)
            self.green = Double(white)
            self.blue = Double(white)
            self.alpha = Double(alpha)
            return
        }

        if let components = uiColor.cgColor.components {
            if components.count >= 3 {
                self.red = Double(components[0])
                self.green = Double(components[1])
                self.blue = Double(components[2])
                self.alpha = Double(uiColor.cgColor.alpha)
                return
            }
            if components.count == 2 {
                self.red = Double(components[0])
                self.green = Double(components[0])
                self.blue = Double(components[0])
                self.alpha = Double(components[1])
                return
            }
        }

        return nil
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

struct CanvasSize: Codable {
    let width: Double
    let height: Double
}

struct DrawingBox: Codable {
    let topLeft: SerializablePoint
    let bottomRight: SerializablePoint
}

struct ManualMenuItem: Identifiable, Codable {
    let id: Int
    let title: String
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
    let canvasSize: CanvasSize?
    let drawingBox: DrawingBox?
}
