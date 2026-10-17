import UIKit

/// A 1000px-square model image makes pixel and 0..1000 model coordinates identical.
/// Letterboxing preserves the phone's aspect ratio; gestures are unboxed exactly once.
struct ModelViewport {
    static let side: CGFloat = 1000
    let content: CGRect

    init(size: CGSize) {
        let scale = Self.side / max(max(size.width, size.height), 1)
        let width = size.width * scale, height = size.height * scale
        content = CGRect(x: (Self.side - width) / 2, y: (Self.side - height) / 2,
                         width: width, height: height)
    }

    func image(_ data: Data) throws -> Data {
        guard content.width > 0, content.height > 0, let source = UIImage(data: data) else {
            throw BlindError(reason: "cannot prepare a valid model screenshot")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: Self.side, height: Self.side), format: format)
        return renderer.jpegData(withCompressionQuality: 0.85) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            source.draw(in: content)
        }
    }

    func canvasPoint(_ phone: CGPoint) -> CGPoint {
        CGPoint(x: content.minX + phone.x / 1000 * content.width,
                y: content.minY + phone.y / 1000 * content.height)
    }

    private func phonePoint(_ point: CGPoint) throws -> CGPoint {
        guard content.width > 0, content.height > 0, point.x.isFinite, point.y.isFinite,
              point.x >= content.minX - 0.5, point.x <= content.maxX + 0.5,
              point.y >= content.minY - 0.5, point.y <= content.maxY + 0.5 else {
            throw Actions.ParseError(message: "target lies outside the phone on the 1000x1000 canvas; do not click black padding")
        }
        // At most half a canvas pixel of integer rounding, never arbitrary edge clamping.
        let x = min(max(point.x, content.minX), content.maxX)
        let y = min(max(point.y, content.minY), content.maxY)
        return CGPoint(x: (x - content.minX) / content.width * 1000,
                       y: (y - content.minY) / content.height * 1000)
    }

    func phoneAction(_ action: JObject) throws -> JObject { try map(action, toPhone: true) }
    func canvasAction(_ action: JObject) throws -> JObject { try map(action, toPhone: false) }

    private func map(_ action: JObject, toPhone: Bool) throws -> JObject {
        var out = action
        func point(_ x: Double, _ y: Double) throws -> CGPoint {
            let p = CGPoint(x: x, y: y)
            if toPhone { return try phonePoint(p) }
            return canvasPoint(p)
        }
        func pair(_ x: String, _ y: String) throws {
            guard let px = action[x]?.double, let py = action[y]?.double else {
                throw Actions.ParseError(message: "missing gesture coordinates")
            }
            let p = try point(px, py)
            out[x] = .int(Int(p.x.rounded())); out[y] = .int(Int(p.y.rounded()))
        }
        switch action["action"]?.str {
        case "tap": try pair("x", "y")
        case "swipe": try pair("x1", "y1"); try pair("x2", "y2")
        case "circle":
            try pair("x", "y")
            guard let radius = action["r"]?.double, radius.isFinite, radius > 0 else {
                throw Actions.ParseError(message: "invalid circle radius")
            }
            if toPhone, let x = action["x"]?.double, let y = action["y"]?.double {
                _ = try phonePoint(CGPoint(x: x - radius, y: y - radius))
                _ = try phonePoint(CGPoint(x: x + radius, y: y + radius))
            }
            let mapped = toPhone ? radius / content.width * 1000 : radius / 1000 * content.width
            out["r"] = .int(Int(mapped.rounded()))
        case "path":
            guard let raw = action["points"], case .arr(let points) = raw else { throw Actions.ParseError(message: "missing path") }
            out["points"] = .arr(try points.map { value in
                guard case .arr(let xy) = value, xy.count == 2,
                      let x = xy[0].double, let y = xy[1].double else { throw Actions.ParseError(message: "invalid path point") }
                let p = try point(x, y)
                return .arr([.int(Int(p.x.rounded())), .int(Int(p.y.rounded()))])
            })
        default: break
        }
        return out
    }
}
