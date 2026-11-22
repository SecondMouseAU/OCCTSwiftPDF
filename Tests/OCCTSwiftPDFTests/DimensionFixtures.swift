import Foundation

@testable import OCCTSwiftPDF

/// A sheet written by hand, in millimetres on the paper, that draws dimensions the way a CAD
/// writer does: a dimension line, extension lines or arrowheads at its ends, and the value as text.
///
/// The content is built by appending, one statement at a time, since a long literal expression
/// can fail to type-check on the older Swift of the CI runners.
struct DimensionSheet {
    /// The text height in millimetres.
    var textHeight = 2.5
    var content = ""
    /// The properties name (`oc1`) of the optional content group that lines and text are drawn in,
    /// or `nil` for none; `pdf` declares groups `oc1` (Lines) and `oc2` (Text).
    var lineGroup: String?
    var textGroup: String?

    static let pointsPerMillimetre = 72.0 / 25.4

    static func pt(_ millimetres: Double) -> String {
        String(format: "%.4f", millimetres * pointsPerMillimetre)
    }

    /// A stroked line.
    mutating func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        if let lineGroup { content += "/OC /\(lineGroup) BDC " }
        content += "\(Self.pt(x1)) \(Self.pt(y1)) m \(Self.pt(x2)) \(Self.pt(y2)) l S"
        content += lineGroup == nil ? "\n" : " EMC\n"
    }

    /// Text with its baseline starting at (`x`, `y`).
    mutating func text(_ string: String, _ x: Double, _ y: Double) {
        let size = Self.pt(textHeight)
        if let textGroup { content += "/OC /\(textGroup) BDC " }
        content += "BT /F1 \(size) Tf 1 0 0 1 \(Self.pt(x)) \(Self.pt(y)) Tm (\(string)) Tj ET"
        content += textGroup == nil ? "\n" : " EMC\n"
    }

    /// A filled triangle whose tip is at (`x`, `y`), pointing along `direction` (1 is to the
    /// right, -1 to the left), 3 mm long and 1.2 mm across: the arrowhead of a dimension line.
    mutating func arrow(_ x: Double, _ y: Double, pointing direction: Double) {
        let back = x - direction * 3
        content += "\(Self.pt(x)) \(Self.pt(y)) m \(Self.pt(back)) \(Self.pt(y + 0.6)) l "
        content += "\(Self.pt(back)) \(Self.pt(y - 0.6)) l f\n"
    }

    /// A horizontal dimension from `x1` to `x2` with its line at `y`.
    ///
    /// `value` is its text above the middle. Its ends are marked by extension lines crossing the
    /// line, or by arrowheads.
    mutating func horizontal(
        _ x1: Double, _ x2: Double, y: Double, value: String, extensionLines: Bool = true,
        arrowheads: Bool = false
    ) {
        line(x1, y, x2, y)
        if extensionLines {
            line(x1, y - 3, x1, y + 2)
            line(x2, y - 3, x2, y + 2)
        }
        if arrowheads {
            arrow(x1, y, pointing: -1)
            arrow(x2, y, pointing: 1)
        }
        // The font has no widths, so each character advances half an em.
        let width = Double(value.count) * 0.5 * textHeight
        text(value, (x1 + x2) / 2 - width / 2, y + 1)
    }

    /// The sheet as a PDF.
    var pdf: MiniPDF {
        var pdf = MiniPDF(content: content)
        pdf.objects = [
            MiniPDF.helvetica, "<< /Type /OCG /Name (Lines) >>", "<< /Type /OCG /Name (Text) >>",
        ]
        pdf.resources = "<< /Font << /F1 {1} >> /Properties << /oc1 {2} /oc2 {3} >> >>"
        pdf.catalogExtra = "/OCProperties << /OCGs [{2} {3}] /D << /ON [{2} {3}] >> >>"
        return pdf
    }

    func page() throws -> PDF.Page { try InterpreterTests.page(pdf) }

    /// The text of a length drawn at the scale: `"100"` for 50 mm at 1:2.
    static func value(_ drawn: Double, scale: Double) -> String {
        String(Int((drawn * scale).rounded()))
    }

    /// Adds `count` horizontal dimensions in a column whose left edge is `x`, drawn at `scale`
    /// (the real value per millimetre on the paper) from `y`, 8 mm apart, in lengths that differ.
    mutating func column(
        x: Double, y: Double, count: Int, scale: Double, extensionLines: Bool = true,
        arrowheads: Bool = false
    ) {
        for index in 0..<count {
            let drawn = 22.0 + Double((index * 7) % 23) * 2.0 + Double(index)
            horizontal(
                x, x + drawn, y: y + Double(index) * 8, value: Self.value(drawn, scale: scale),
                extensionLines: extensionLines, arrowheads: arrowheads)
        }
    }
}
