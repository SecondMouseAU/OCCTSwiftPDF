// TextAssembly.swift
// OCCTSwiftPDF
//
// Joins text runs that continue one another along a baseline into one run. Some writers show one
// character per operation (the Jw_cad PDFs printed through Acrobat PDFWriter do), so a dimension
// value such as `10,439` is only a string once its characters are joined.

import CoreGraphics
import Foundation

enum TextAssembly {
    /// The runs, in content order, with each run that continues the one before it joined to it.
    ///
    /// A run continues the line when it has the same font, direction (within 1 degree), size
    /// (within 10 percent), layer and visibility, starts on the line's baseline (within 15 percent
    /// of the size), and starts no more than 0.3 of the size back from the line's end or 0.8 ahead
    /// of it. A gap over 0.3 of the size becomes a space. Runs in different fonts stay apart, so
    /// each keeps the way it was decoded.
    static func lines(_ runs: [PDF.TextRun]) -> [PDF.TextRun] {
        var out: [PDF.TextRun] = []
        for run in runs {
            if var line = out.last, let gap = continuation(of: line, by: run) {
                join(&line, run, space: gap > 0.3 * line.height)
                out[out.count - 1] = line
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// How far along the baseline the run starts past the line's end, when it continues the line.
    static func continuation(of line: PDF.TextRun, by run: PDF.TextRun) -> Double? {
        let h = line.height
        guard h > 0, run.height > 0, abs(run.height - h) <= 0.1 * h,
            run.fontName == line.fontName, run.layer == line.layer,
            run.isInvisible == line.isInvisible,
            abs(angleBetween(run.rotationDeg, line.rotationDeg)) <= 1
        else { return nil }
        let angle = line.rotationDeg * .pi / 180
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let end = line.quad[1]
        let dx = run.origin.x - end.x
        let dy = run.origin.y - end.y
        let along = dx * direction.x + dy * direction.y
        let across = -dx * direction.y + dy * direction.x
        guard abs(across) <= 0.15 * h, along >= -0.3 * h, along <= 0.8 * h else { return nil }
        return along
    }

    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func join(_ line: inout PDF.TextRun, _ run: PDF.TextRun, space: Bool) {
        func joined(_ a: String?, _ b: String?) -> String? {
            guard let a, let b else { return nil }
            return a + (space ? " " : "") + b
        }
        line.codes += run.codes
        line.codeCount += run.codeCount
        line.text = joined(line.text, run.text)
        line.ownText = joined(line.ownText, run.ownText)
        line.pdfKitText = joined(line.pdfKitText, run.pdfKitText)
        if run.decoding != line.decoding, line.decoding != .none {
            line.decoding =
                run.text == nil ? .none : (run.decoding == .pdfKit ? .pdfKit : line.decoding)
        }
        let up = CGPoint(x: line.quad[3].x - line.quad[0].x, y: line.quad[3].y - line.quad[0].y)
        let end = run.quad[1]
        line.quad = [line.quad[0], end, CGPoint(x: end.x + up.x, y: end.y + up.y), line.quad[3]]
        line.width = hypot(end.x - line.origin.x, end.y - line.origin.y)
        line.parts.append(run.source)
    }
}
