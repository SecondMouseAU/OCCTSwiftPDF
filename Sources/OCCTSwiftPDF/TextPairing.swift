// TextPairing.swift
// OCCTSwiftPDF
//
// Each text run paired with the characters PDFKit finds in its box.

import CoreGraphics
import Foundation
import PDFKit

/// Pairs text runs with the characters PDFKit finds in their boxes.
///
/// PDFKit decodes some text this reader cannot (fonts it gives no other way back from codes to
/// characters). Its selections are in the same page coordinates the interpreter uses, and only runs
/// along or across the page (within 1 degree) are paired. A character's
/// box must be asked for through a selection: `characterBounds(at:)` indexes PDFKit's own character
/// list, which is not `PDFPage.string`, since the string has spaces and line breaks added.
enum TextPairing {
    static func pair(_ runs: inout [PDF.TextRun], with page: PDFPage) {
        for index in runs.indices {
            let run = runs[index]
            // PDFKit is asked through an axis-aligned box, which fits a run only when it runs
            // along or across the page; an inclined run's box takes in its neighbours.
            let quarterTurns = run.rotationDeg / 90
            guard run.width > 0, run.height > 0,
                abs(quarterTurns - quarterTurns.rounded()) < 1.0 / 90,
                let rect = innerRect(run)
            else { continue }
            let found = page.selection(for: rect)?.string?
                .filter { !$0.isWhitespace && !$0.isNewline }
            guard let found, !found.isEmpty else { continue }
            runs[index].pdfKitText = found
            // PDFKit's characters stand in where this reader has none, where it only guessed
            // ASCII and PDFKit disagrees, and where a code was missing from the ToUnicode map.
            let own = run.text?.filter { !$0.isWhitespace }
            let replace =
                run.text == nil || (run.decoding == .asciiGuess && own != found)
                || (run.text?.contains("\u{FFFD}") == true && !found.contains("\u{FFFD}"))
            if replace {
                runs[index].text = found
                runs[index].decoding = .pdfKit
            }
        }
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
