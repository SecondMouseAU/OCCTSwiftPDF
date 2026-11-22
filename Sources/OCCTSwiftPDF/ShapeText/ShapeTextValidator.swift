// ShapeTextValidator.swift
// OCCTSwiftPDF
//
// The third step of recovering text drawn as shapes: deciding whether what was recognised may be
// believed. Pure arithmetic on a recognised line and the region it was found for, with no Vision
// in it, so every rule can be tested on any platform.

import CoreGraphics
import Foundation

/// A recognised line, in the frame of the region it was found for.
struct FramedLine {
    var text: String
    var confidence: Double
    /// Bottom left, bottom right, top right, top left, as (`a`, `b`) in the region's frame.
    var corners: [CGPoint]
    /// How far its baseline is turned from the region's reading direction, in degrees from 0 to
    /// 180.
    var directionError: Double

    init(text: String, confidence: Double, corners: [CGPoint]) {
        self.text = text
        self.confidence = confidence
        self.corners = corners
        if corners.count == 4 {
            let along = CGPoint(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y)
            directionError = abs(atan2(along.y, along.x) * 180 / .pi)
        } else {
            directionError = 180
        }
    }

    init(text: String, confidence: Double, box: CGRect, directionError: Double) {
        self.text = text
        self.confidence = confidence
        corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ]
        self.directionError = directionError
    }

    /// The bounding rectangle of its corners.
    var box: CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else {
            return .null
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

enum ShapeTextValidator {
    enum Verdict: Equatable {
        case accepted(text: String, confidence: Double)
        /// Rejected, with the text recognised where there was some.
        case rejected(PDF.ShapeTextRejection, text: String?)
    }

    /// Whether the lines recognised in a region's crop are text drawn by the region's shapes.
    ///
    /// The lines that overlap the region's box are the ones about it; the rest are neighbours that
    /// came into the crop's margin. Several lines about it are accepted only as one line cut in
    /// pieces (on one baseline, in order, not overlapping), which are then taken as one. The line
    /// must then pass, in this order: confidence; characters; position; direction; height; glyph
    /// count; advance. The first to fail is the reason given.
    static func validate(
        _ lines: [FramedLine], in region: ShapeTextRegion, options: PDF.ShapeTextOptions
    ) -> Verdict {
        guard let any = lines.max(by: { $0.confidence < $1.confidence }) else {
            return .rejected(.noText, text: nil)
        }
        let box = CGRect(x: 0, y: 0, width: region.length, height: region.height)
        let about = lines.filter {
            let overlap = box.intersection($0.box)
            return !overlap.isNull && area(overlap) >= 0.25 * area($0.box)
        }
        guard let line = oneLine(about, height: region.height) else {
            return .rejected(about.isEmpty ? .position : .ambiguous, text: any.text)
        }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        func reject(_ reason: PDF.ShapeTextRejection) -> Verdict {
            .rejected(reason, text: text)
        }

        guard line.confidence >= options.minimumConfidence else { return reject(.lowConfidence) }
        guard plausibleCharacters(text) else { return reject(.characters) }
        guard intersectionOverUnion(box, line.box) >= options.minimumOverlap else {
            return reject(.position)
        }
        guard line.directionError <= options.maximumDirectionError else {
            return reject(.direction)
        }
        guard region.height > 0, options.heightRatio.contains(line.box.height / region.height)
        else { return reject(.height) }
        let characters = text.filter { !$0.isWhitespace }.count
        guard plausibleCount(characters, glyphs: region.glyphs, stroked: region.mostlyStroked)
        else { return reject(.glyphCount) }
        if text.count >= 2 {
            let advance = region.length / (Double(text.count) * region.height)
            guard options.advance.contains(advance) else { return reject(.advance) }
        }
        return .accepted(text: text, confidence: line.confidence)
    }

    /// The Unicode blocks a drawing's text is in: Latin (with its accents), Greek and Cyrillic,
    /// punctuation, scripts, currency (the euro only), letterlike symbols, number forms, arrows,
    /// mathematical operators and the technical symbols (the diameter sign).
    static let plausibleBlocks: [ClosedRange<UInt32>] = [
        0x0020...0x024F, 0x0370...0x03FF, 0x0400...0x04FF, 0x2000...0x209F, 0x20AC...0x20AC,
        0x2100...0x218F, 0x2190...0x21FF, 0x2200...0x22FF, 0x2300...0x23FF,
    ]

    /// At least one letter or digit, and nothing a drawing's text would not hold.
    ///
    /// That is: no replacement or control character, no character outside the blocks in
    /// ``plausibleBlocks`` (a recogniser that cannot tell a glyph reads it as a Thai or an Arabic
    /// one, say), and no word that mixes Latin and Cyrillic letters (a look-alike for a Latin one:
    /// `А`, `І`).
    static func plausibleCharacters(_ text: String) -> Bool {
        guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return false
        }
        let clean = text.unicodeScalars.allSatisfy { scalar in
            scalar != "\u{FFFD}" && !CharacterSet.controlCharacters.contains(scalar)
                && plausibleBlocks.contains { $0.contains(scalar.value) }
        }
        return clean && !text.split(whereSeparator: \.isWhitespace).contains(where: mixesScripts)
    }

    /// Whether a word has both Cyrillic letters and other letters.
    static func mixesScripts(_ word: Substring) -> Bool {
        var cyrillic = false
        var other = false
        for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
            if (0x400...0x52F).contains(scalar.value) { cyrillic = true } else { other = true }
        }
        return cyrillic && other
    }

    /// Whether `characters` (not counting spaces) can be what `glyphs` pieces draw.
    ///
    /// A filled outline is one piece to a character, two or three for those with parts that do not
    /// touch (`i`, `:`, `%`) or that a pen font draws as several filled strokes (the UK railway
    /// sheets' `A`, `W`), and a few fewer where characters run together, so the characters are
    /// from a third of the pieces to 1.3 times them and one more. A stroked character is several
    /// strokes, up to six, so the lower bound is a sixth.
    static func plausibleCount(_ characters: Int, glyphs: Int, stroked: Bool) -> Bool {
        let lowest = (Double(glyphs) / (stroked ? 6 : 3)).rounded(.up)
        let highest = (1.3 * Double(glyphs)).rounded(.down) + 1
        return Double(characters) >= lowest && Double(characters) <= highest
    }

    /// The one line the lines about a region make: the single one, or several on one baseline,
    /// in order along it and not overlapping, joined with spaces.
    static func oneLine(_ lines: [FramedLine], height: Double) -> FramedLine? {
        guard lines.count > 1 else { return lines.first }
        let ordered = lines.sorted { $0.box.midX < $1.box.midX }
        let centres = ordered.map { $0.box.midY }
        guard let low = centres.min(), let high = centres.max(), high - low <= 0.3 * height
        else { return nil }
        for (before, after) in zip(ordered, ordered.dropFirst())
        where after.box.minX < before.box.maxX - 0.1 * height {
            return nil
        }
        let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
        return FramedLine(
            text: ordered.map(\.text).joined(separator: " "),
            confidence: ordered.map(\.confidence).min() ?? 0, box: box,
            directionError: ordered.map(\.directionError).max() ?? 0)
    }

    static func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : rect.width * rect.height }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let shared = area(a.intersection(b))
        let total = area(a) + area(b) - shared
        return total > 0 ? shared / total : 0
    }
}
