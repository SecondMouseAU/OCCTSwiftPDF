import CoreGraphics
import CoreText
import Foundation

/// Text drawn as shapes, for fixtures: a string's glyph outlines from CoreText, written as content
/// stream path operators, filled (as Microsoft Print to PDF draws text) or stroked (hollow, as a
/// plotter draws outlines).
enum OutlineText {
    /// The operators, and the ink's box (tight, in page coordinates).
    struct Drawn {
        var content: String
        var ink: CGRect
    }

    static func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }

    /// `string` set in `fontName` at `size`, its baseline starting at `origin` and turned
    /// `rotationDegrees` counterclockwise about it.
    static func drawn(
        _ string: String, fontName: String = "Helvetica", size: Double = 10, at origin: CGPoint,
        rotationDegrees: Double = 0, stroke: Bool = false
    ) -> Drawn {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes))
        let turn = rotationDegrees * .pi / 180
        var content = stroke ? "0.3 w\n" : ""
        var ink = CGRect.null
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(font, glyphs[index], nil) else {
                    continue
                }
                var place = CGAffineTransform(translationX: origin.x, y: origin.y)
                place = place.rotated(by: turn)
                place = place.translatedBy(x: positions[index].x, y: positions[index].y)
                guard let path = outline.copy(using: &place) else { continue }
                content += operators(path)
                content += stroke ? "S\n" : "f\n"
                ink = ink.union(path.boundingBox)
            }
        }
        return Drawn(content: content, ink: ink)
    }

    /// Path construction operators for a path; a quadratic curve is raised to a cubic one.
    static func operators(_ path: CGPath) -> String {
        var out = ""
        var current = CGPoint.zero
        var start = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                start = current
                out += "\(number(current.x)) \(number(current.y)) m\n"
            case .addLineToPoint:
                current = element.points[0]
                out += "\(number(current.x)) \(number(current.y)) l\n"
            case .addQuadCurveToPoint:
                let control = element.points[0]
                let end = element.points[1]
                let c1x = current.x + 2 * (control.x - current.x) / 3
                let c1y = current.y + 2 * (control.y - current.y) / 3
                let c2x = end.x + 2 * (control.x - end.x) / 3
                let c2y = end.y + 2 * (control.y - end.y) / 3
                out += "\(number(c1x)) \(number(c1y)) \(number(c2x)) \(number(c2y)) "
                out += "\(number(end.x)) \(number(end.y)) c\n"
                current = end
            case .addCurveToPoint:
                let c1 = element.points[0]
                let c2 = element.points[1]
                let end = element.points[2]
                out += "\(number(c1.x)) \(number(c1.y)) \(number(c2.x)) \(number(c2.y)) "
                out += "\(number(end.x)) \(number(end.y)) c\n"
                current = end
            case .closeSubpath:
                out += "h\n"
                current = start
            @unknown default:
                break
            }
        }
        return out
    }
}
