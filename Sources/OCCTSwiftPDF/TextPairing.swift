// TextPairing.swift
// OCCTSwiftPDF
//
// Each text run paired with the characters PDFKit finds in its box: the geometry of the
// question here, the asking in TextPairing+PDFKit.swift.

import CoreGraphics
import Foundation

/// Pairs text runs with the characters PDFKit finds for them.
///
/// PDFKit decodes some text this reader cannot (fonts it gives no other way back from codes to
/// characters). Its selections are in the same page coordinates the interpreter uses.
///
/// - A run along or across the page is asked for through an axis-aligned box around it. A
///   character's box must be asked for through a selection: `characterBounds(at:)` indexes
///   PDFKit's own character list, which is not `PDFPage.string`, since the string has spaces and
///   line breaks added.
/// - An inclined run's axis-aligned box would take in its neighbours, so it is asked for from a
///   point inside its first character to its end, which follows PDFKit's own text flow along the
///   run.
enum TextPairing {
    /// The points to select between: inside the run's first character (a tenth of its height in
    /// from its start) and at its end, a third of its height above the baseline.
    ///
    /// PDFKit takes a character at the end of a selection only when the point is past the
    /// character's middle, so the second point is the run's end itself.
    static func endPoints(_ run: PDF.TextRun) -> (CGPoint, CGPoint)? {
        guard run.quad.count == 4 else { return nil }
        let base = run.quad[0]
        let along = CGPoint(x: run.quad[1].x - base.x, y: run.quad[1].y - base.y)
        let up = CGPoint(x: run.quad[3].x - base.x, y: run.quad[3].y - base.y)
        let length = max(hypot(along.x, along.y), 1e-9)
        let inset = min(run.height * 0.1, length * 0.25) / length
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: base.x + along.x * t + up.x / 3, y: base.y + along.y * t + up.y / 3)
        }
        return (point(inset), point(1))
    }

    /// The axis-aligned box around the run from its baseline to 75 percent of its height, short
    /// of each end by a tenth of its height.
    ///
    /// PDFKit selects a character when the centre of its box is inside the rectangle, and its
    /// boxes run from the font's descender to its ascender, so the centres sit about a quarter of
    /// the size above the baseline. The band takes those and leaves out the lines above and below.
    static func innerRect(_ run: PDF.TextRun) -> CGRect? {
        guard run.quad.count == 4 else { return nil }
        let base = run.quad[0]
        let along = CGPoint(x: run.quad[1].x - base.x, y: run.quad[1].y - base.y)
        let up = CGPoint(x: run.quad[3].x - base.x, y: run.quad[3].y - base.y)
        let length = max(hypot(along.x, along.y), 1e-9)
        let inset = min(run.height * 0.1, length * 0.25) / length
        var points: [CGPoint] = []
        for t in [inset, 1 - inset] {
            for v in [0.0, 0.75] {
                points.append(
                    CGPoint(x: base.x + along.x * t + up.x * v, y: base.y + along.y * t + up.y * v))
            }
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
