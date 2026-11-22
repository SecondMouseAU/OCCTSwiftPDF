import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Dimensions rebuilt from a page's loose pieces, and the scale of each view, on PDFs written by
/// hand so that every piece and every value is known.
@Suite("Dimensions")
struct DimensionTests {
    /// The number of dimensions a rebuilt value text names, by text.
    static func texts(_ recovery: PDF.DimensionRecovery) -> [String] {
        recovery.dimensions.compactMap(\.textOverride)
    }

    /// Why the value `text` was not rebuilt, or `nil` when it has no such warning.
    static func reason(_ recovery: PDF.DimensionRecovery, _ text: String)
        -> DXF.DimensionRebuild.Reason?
    {
        for case .valueNotExplained(let value, _, let reason) in recovery.warnings
        where value == text {
            return reason
        }
        return nil
    }

    static func unexplained(_ recovery: PDF.DimensionRecovery) -> [String] {
        recovery.warnings.compactMap {
            if case .valueNotExplained(let text, _, _) = $0 { return text }
            return nil
        }
    }

    @Test("extension lines and values give each dimension, and the scale they agree on")
    func extensionLines() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        let recovery = try sheet.page().recoveringDimensions()
        #expect(recovery.dimensions.count == 6)
        let scale = try #require(recovery.scale)
        #expect(abs(scale - 2) < 1e-9)
        let view = try #require(recovery.views.first)
        #expect(view.supporting == 6)
        #expect(view.contradicting == 0)
        #expect(view.alternative == nil)
        #expect(recovery.warnings.isEmpty)
        for dimension in recovery.dimensions {
            // Marked as rebuilt, with its scale and the pieces it was made of.
            let rebuilt = try #require(dimension.rebuilt)
            #expect(abs(rebuilt.scale - 2) < 1e-9)
            #expect(rebuilt.pieces.count >= 2)
            // The length the geometry gives, in millimetres on the paper, times the scale is the
            // value the text states.
            let text = try #require(dimension.textOverride)
            let measured = try #require(dimension.measurement)
            #expect(abs(measured * 2 - (Double(text) ?? -1)) < 0.5, "\(text)")
        }
    }

    @Test("arrowheads that are filled paths end a dimension line that no extension line meets")
    func arrowheads() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2, extensionLines: false, arrowheads: true)
        let page = try sheet.page()
        let recovery = page.recoveringDimensions()
        #expect(recovery.dimensions.count == 6)
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
        // Without them the ends are not there: nothing to measure between.
        let without = page.recoveringDimensions(PDF.DimensionOptions(arrowheads: false))
        #expect(without.dimensions.isEmpty)
        #expect(without.scale == nil)
        // The page's own drawing is as it was: the arrowheads are `skipped["FILL"]`, not drawn.
        let drawing = page.drawing()
        #expect(drawing.skipped["FILL"] == 12)
        #expect(drawing.counts.point == 0)
        #expect(drawing.counts.polyline == 0)
    }

    @Test("an arrowhead where an extension line already ends the dimension line adds no mark")
    func arrowheadsAddNothingWhereTheEndIsMarked() throws {
        var both = DimensionSheet()
        both.column(x: 30, y: 60, count: 6, scale: 2, arrowheads: true)
        #expect(try both.page().workingDrawing(arrowheads: true).counts.point == 0)
        var only = DimensionSheet()
        only.column(x: 30, y: 60, count: 6, scale: 2, extensionLines: false, arrowheads: true)
        #expect(try only.page().workingDrawing(arrowheads: true).counts.point == 12)
        // Both give the same dimensions, at the same scale.
        let withBoth = try both.page().recoveringDimensions()
        let withTips = try only.page().recoveringDimensions()
        #expect(withBoth.dimensions.count == 6)
        #expect(Self.texts(withBoth) == Self.texts(withTips))
        #expect(withBoth.scale == withTips.scale)
    }

    @Test("lines and text on different layers still make a dimension, which keeps its text's layer")
    func layers() throws {
        var sheet = DimensionSheet()
        sheet.lineGroup = "oc1"
        sheet.textGroup = "oc2"
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        let page = try sheet.page()
        #expect(Set(page.layers) == ["Lines", "Text"])
        let recovery = page.recoveringDimensions()
        #expect(recovery.dimensions.count == 6)
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
        for dimension in recovery.dimensions { #expect(dimension.layer == "Text") }
    }

    @Test("a filled path that is not an arrowhead is not an end")
    func notArrowheads() throws {
        // A fat triangle (no narrow tip), a filled rectangle and a triangle among other shapes in
        // one path: none is an arrowhead.
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2, extensionLines: false)
        let pt = DimensionSheet.pt
        sheet.content += "\(pt(80)) \(pt(60)) m \(pt(82)) \(pt(60)) l \(pt(81)) \(pt(62)) l f\n"
        sheet.content += "\(pt(90)) \(pt(60)) \(pt(2)) \(pt(1)) re f\n"
        sheet.content += "\(pt(100)) \(pt(60)) m \(pt(103)) \(pt(60.6)) l \(pt(103)) \(pt(59.4)) l "
        sheet.content += "\(pt(110)) \(pt(60)) m \(pt(112)) \(pt(65)) l \(pt(114)) \(pt(60)) l "
        sheet.content += "\(pt(114)) \(pt(58)) l \(pt(110)) \(pt(58)) l f\n"
        let page = try sheet.page()
        let working = page.workingDrawing(arrowheads: true)
        #expect(working.counts.point == 0)
        #expect(page.recoveringDimensions().dimensions.isEmpty)
    }

    @Test("a triangle with a vertex on its base is an arrowhead, and its tip is the end")
    func dart() throws {
        let triangle = [CGPoint(x: 10, y: 5), CGPoint(x: 14, y: 4), CGPoint(x: 14, y: 6)]
        let subpath = PDF.Subpath(
            start: CGPoint(x: 10, y: 5),
            segments: [
                .line(to: CGPoint(x: 14, y: 4)), .line(to: CGPoint(x: 14, y: 5)),
                .line(to: CGPoint(x: 14, y: 6)), .line(to: CGPoint(x: 10, y: 5)),
            ], isClosed: true)
        let corners = try #require(PDF.Page.triangle(subpath, .identity))
        #expect(corners.count == 3)
        let arrowhead = try #require(PDF.Page.arrowhead(of: corners))
        #expect(arrowhead.tip == DXF.Point2(triangle[0].x, triangle[0].y))
        // It points left, away from its base.
        #expect(abs(arrowhead.direction.x + 1) < 1e-9 && abs(arrowhead.direction.y) < 1e-9)
    }

    @Test("a value no dimension explains is a warning, and no dimension is guessed")
    func unexplainedValue() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        // 30 mm drawn, and the text says 77: at 1:2 it should say 60.
        sheet.horizontal(30, 60, y: 108, value: "77")
        let recovery = try sheet.page().recoveringDimensions()
        #expect(recovery.dimensions.count == 6)
        #expect(!Self.texts(recovery).contains("77"))
        #expect(Self.unexplained(recovery) == ["77"])
        let view = try #require(recovery.views.first)
        #expect(view.supporting == 6)
        #expect(view.contradicting == 1)
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
    }

    @Test("too few values to agree on a scale give no dimensions")
    func tooFew() throws {
        var sheet = DimensionSheet()
        sheet.horizontal(30, 80, y: 60, value: "100")
        sheet.horizontal(30, 70, y: 100, value: "33")
        let recovery = try sheet.page().recoveringDimensions()
        #expect(recovery.dimensions.isEmpty)
        #expect(recovery.scale == nil)
        #expect(Self.unexplained(recovery).sorted() == ["100", "33"])
        for view in recovery.views { #expect(view.scale == nil && view.dimensions.isEmpty) }
    }

    @Test(
        "values with a unit, a tolerance or several numbers are listed with the reason, not rebuilt"
    )
    func unsupportedValues() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        sheet.horizontal(30, 70, y: 130, value: "80mm")
        sheet.horizontal(30, 70, y: 140, value: "80+0.1")
        sheet.horizontal(30, 70, y: 150, value: "3 ft")
        let recovery = try sheet.page().recoveringDimensions()
        // `80mm` is a millimetre value and is rebuilt; the others are not numbers to rebuild.
        #expect(Self.texts(recovery).contains("80mm"))
        #expect(Self.reason(recovery, "80+0.1") == .severalNumbers)
        #expect(Self.reason(recovery, "3 ft") == .unit)
        #expect(!Self.texts(recovery).contains("80+0.1"))
        #expect(!Self.texts(recovery).contains("3 ft"))
    }

    @Test("values with decimals are explained to the last place they state")
    func decimals() throws {
        // At 2:1 each value is half the drawn length: 22 mm is 11.0, 37 mm is 18.5.
        var sheet = DimensionSheet()
        let drawn = [22.0, 37.0, 45.0, 53.0, 61.0, 74.0]
        let values = ["11.0", "18.5", "22.5", "26.5", "30.5", "37.0"]
        for (index, length) in drawn.enumerated() {
            sheet.horizontal(30, 30 + length, y: 60 + Double(index) * 8, value: values[index])
        }
        let recovery = try sheet.page().recoveringDimensions()
        #expect(Self.texts(recovery).sorted() == values.sorted())
        #expect(abs((recovery.scale ?? 0) - 0.5) < 1e-9)
        // A value off by a tenth of a unit more than it states is not explained.
        var off = sheet
        off.horizontal(30, 52, y: 120, value: "11.3")
        let other = try off.page().recoveringDimensions()
        #expect(Self.unexplained(other) == ["11.3"])
    }

    @Test("a radius symbol on a straight dimension is flagged, and the geometry gives the kind")
    func radiusSymbol() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        // 10 mm drawn is 20 at 1:2, but it is a straight dimension, not a radius.
        sheet.horizontal(30, 40, y: 108, value: "R20")
        let recovery = try sheet.page().recoveringDimensions()
        let dimension = try #require(recovery.dimensions.first { $0.textOverride == "R20" })
        #expect(dimension.kind == .linear)
        let flagged = recovery.warnings.contains {
            if case .symbolDisagrees(let text, _, _) = $0 { return text == "R20" }
            return false
        }
        #expect(flagged)
    }

    @Test("what the convention says of a comma is what is read")
    func numberConventions() throws {
        var sheet = DimensionSheet()
        let drawn = [22.8625, 15.0, 30.0, 25.0, 18.75]
        let values = ["1,829", "1,200", "2,400", "2,000", "1,500"]
        for (index, length) in drawn.enumerated() {
            sheet.horizontal(30, 30 + length, y: 60 + Double(index) * 8, value: values[index])
        }
        let page = try sheet.page()
        // A comma that is not part of a number leaves two numbers in each text.
        let plain = page.recoveringDimensions(PDF.DimensionOptions(numbers: .plain))
        #expect(plain.dimensions.isEmpty)
        // A comma that is the decimal mark reads 1.829, a scale of 0.08, which no sheet of paper is
        // credibly at unless it is said to be.
        let decimal = PDF.DimensionOptions(numbers: .commaIsDecimalMark)
        #expect(page.recoveringDimensions(decimal).dimensions.isEmpty)
        let wide = PDF.DimensionOptions(numbers: .commaIsDecimalMark, scaleRange: 0.01...300)
        let read = page.recoveringDimensions(wide)
        #expect(read.dimensions.count == 5)
        #expect(abs((read.scale ?? 0) - 0.08) < 1e-6)
    }

    @Test("a scale that is not a positive number is none, whatever else is said")
    func invalidScale() throws {
        // At 1:400, outside the range of credible scales: an invalid scale is none, not a scale.
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 6, scale: 400)
        let page = try sheet.page()
        for scale in [0, -2, Double.nan, Double.infinity] {
            let recovery = page.recoveringDimensions(PDF.DimensionOptions(scale: scale))
            #expect(recovery.dimensions.isEmpty, "\(scale)")
            #expect(recovery.scale == nil, "\(scale)")
        }
        let given = page.recoveringDimensions(PDF.DimensionOptions(scale: 400))
        #expect(given.dimensions.count == 6)
    }

    @Test("the gap that parts views is the one asked for, and one view is the whole sheet")
    func viewGap() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 6, scale: 2)
        sheet.column(x: 130, y: 50, count: 6, scale: 2)
        let page = try sheet.page()
        // About 40 mm apart, by default cells of 5 mm: two views.
        #expect(page.recoveringDimensions().views.count == 2)
        // Cells of 60 mm join pieces up to 60 mm apart at least; cells of 10 mm keep these apart.
        #expect(page.recoveringDimensions(PDF.DimensionOptions(viewGap: 60)).views.count == 1)
        #expect(page.recoveringDimensions(PDF.DimensionOptions(viewGap: 10)).views.count == 2)
        let one = page.recoveringDimensions(PDF.DimensionOptions(separateViews: false))
        #expect(one.views.count == 1)
        #expect(one.dimensions.count == 12)
    }

    @Test(
        "a view's own scale where the sheet has none is an alternative, and not yet a disagreement")
    func alternativeWithoutSheetScale() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 8, scale: 2)
        // Eight values in a view that nothing explains: half the sheet's values are not explained
        // by the scale of the other half, so the sheet has no scale.
        for index in 0..<8 {
            let length = 20.0 + Double(index) * 3.7
            sheet.horizontal(
                130, 130 + length, y: 50 + Double(index) * 8, value: String(1_000 + index * 77))
        }
        let recovery = try sheet.page().recoveringDimensions()
        #expect(recovery.scale == nil)
        #expect(recovery.dimensions.isEmpty)
        let view = try #require(recovery.views.first { $0.alternative != nil })
        let alternative = try #require(view.alternative)
        #expect(abs(alternative.scale.scale - 2) < 1e-9)
        #expect(alternative.dimensions.count == 8)
        // One scale on its own is not two that disagree.
        #expect(
            !recovery.warnings.contains { if case .scalesDisagree = $0 { true } else { false } })
    }

    @Test("a segment too long for the grid does not stop the rebuild")
    func hugeCoordinates() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        // A line to 1e22 points, which `drawing()` reads, as lines, polylines and fills.
        sheet.content += "0 0 m 10000000000000000000000 0 l S\n"
        sheet.content += "0 0 m 10000000000000000000000 10000000000000000000000 l S\n"
        let page = try sheet.page()
        let recovery = page.recoveringDimensions()
        #expect(recovery.dimensions.count == 6)
        _ = page.workingDrawing(arrowheads: true)
    }

    @Test("a comma is read as the drawing writes it when told, and by the geometry when not")
    func numbers() throws {
        // 1,829 at 1:80 is 22.8625 mm on the paper.
        var sheet = DimensionSheet()
        let drawn = [22.8625, 15.0, 30.0, 25.0, 18.75]
        let values = ["1,829", "1,200", "2,400", "2,000", "1,500"]
        for (index, length) in drawn.enumerated() {
            sheet.horizontal(30, 30 + length, y: 60 + Double(index) * 8, value: values[index])
        }
        let page = try sheet.page()
        let told = page.recoveringDimensions(
            PDF.DimensionOptions(numbers: .commaSeparatesThousands))
        #expect(told.dimensions.count == 5)
        #expect(abs((told.scale ?? 0) - 80) < 1e-6)
        // Not told, the geometry chooses between 1.829 and 1829, and a reduction wins.
        let free = page.recoveringDimensions()
        #expect(abs((free.scale ?? 0) - 80) < 1e-6)
    }

    @Test("a view whose own values favour another scale says so, and the sheet's scale stays")
    func twoScales() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 10, scale: 2)
        sheet.column(x: 130, y: 50, count: 9, scale: 5)
        let recovery = try sheet.page().recoveringDimensions()
        // The dimensions are at the sheet's scale, the one that explains most values.
        let sheetScale = try #require(recovery.scale)
        #expect(abs(sheetScale - 2) < 1e-9)
        #expect(recovery.dimensions.count == 10)
        for dimension in recovery.dimensions { #expect(dimension.rebuilt?.scale == 2) }
        let left = try #require(recovery.views.first { $0.supporting == 10 })
        let right = try #require(recovery.views.first { $0.supporting == 0 })
        #expect(left.alternative == nil)
        #expect(left.bounds.maxX < right.bounds.minX)
        // The other view's values are not explained by it: they are warnings, each kept.
        #expect(right.contradicting == 9)
        #expect(Self.unexplained(recovery).count == 9)
        // And its own values favour 1:5, with the dimensions that would give: reported, not applied.
        let alternative = try #require(right.alternative)
        #expect(abs(alternative.scale.scale - 5) < 1e-9)
        #expect(alternative.scale.supporting == 9 && alternative.scale.contradicting == 0)
        #expect(alternative.dimensions.count == 9)
        for dimension in alternative.dimensions { #expect(dimension.rebuilt?.scale == 5) }
        // Not averaged: the warning lists the sheet's scale and the view's.
        let disagree = recovery.warnings.contains {
            if case .scalesDisagree(let found) = $0 {
                return found.map(\.scale).sorted().map { Int($0.rounded()) } == [2, 5]
            }
            return false
        }
        #expect(disagree)
    }

    @Test("views are looked at only when asked, and one scale is then all the sheet has")
    func sheetOnly() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 10, scale: 2)
        sheet.column(x: 130, y: 50, count: 9, scale: 5)
        let options = PDF.DimensionOptions(separateViews: false)
        let recovery = try sheet.page().recoveringDimensions(options)
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
        #expect(recovery.dimensions.count == 10)
        #expect(Self.unexplained(recovery).count == 9)
        #expect(recovery.views.allSatisfy { $0.alternative == nil })
        #expect(
            !recovery.warnings.contains { if case .scalesDisagree = $0 { true } else { false } })
    }

    @Test("a weak scale of one view is not reported against the sheet's")
    func weakView() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 10, scale: 2)
        // Three values only, at another scale: below the evidence a view needs to disagree.
        sheet.column(x: 130, y: 50, count: 3, scale: 5)
        let recovery = try sheet.page().recoveringDimensions()
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
        #expect(recovery.dimensions.count == 10)
        #expect(Self.unexplained(recovery).count == 3)
        #expect(recovery.views.allSatisfy { $0.alternative == nil })
        #expect(
            recovery.warnings.allSatisfy { if case .valueNotExplained = $0 { true } else { false } }
        )
    }

    @Test("a view whose own scale is a few percent from the sheet's is not a disagreement")
    func nearScale() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 10, scale: 2)
        // 5 percent off: an estimate from a few values, not another scale.
        sheet.column(x: 130, y: 50, count: 9, scale: 2.1)
        let recovery = try sheet.page().recoveringDimensions()
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
        #expect(recovery.views.allSatisfy { $0.alternative == nil })
        #expect(
            !recovery.warnings.contains { if case .scalesDisagree = $0 { true } else { false } })
    }

    @Test("views agreeing on the scale give one scale for the sheet and nothing to flag")
    func twoViewsAgree() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 8, scale: 2)
        sheet.column(x: 130, y: 50, count: 8, scale: 2)
        let recovery = try sheet.page().recoveringDimensions()
        #expect(recovery.views.count == 2)
        #expect(abs((recovery.scale ?? 0) - 2) < 1e-9)
        #expect(recovery.dimensions.count == 16)
        #expect(recovery.warnings.isEmpty)
        #expect(recovery.views.allSatisfy { $0.alternative == nil && $0.supporting == 8 })
    }

    @Test("a scale no sheet of paper is credibly at is not used, and its values are not explained")
    func scaleRange() throws {
        // At 1:400 each 100 mm of paper is 40 m: outside 10:1 to 1:300.
        var sheet = DimensionSheet()
        sheet.column(x: 20, y: 50, count: 6, scale: 400)
        let page = try sheet.page()
        let recovery = page.recoveringDimensions()
        #expect(recovery.dimensions.isEmpty)
        #expect(recovery.scale == nil)
        #expect(Self.unexplained(recovery).count == 6)
        // Said to be credible, it is used.
        let wide = page.recoveringDimensions(PDF.DimensionOptions(scaleRange: 0.1...1000))
        #expect(wide.dimensions.count == 6)
        #expect(abs((wide.scale ?? 0) - 400) < 1e-6)
    }

    @Test("a scale given is used for every view, and what it does not explain is a warning")
    func givenScale() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        let page = try sheet.page()
        let right = page.recoveringDimensions(PDF.DimensionOptions(scale: 2))
        #expect(right.dimensions.count == 6)
        let wrong = page.recoveringDimensions(PDF.DimensionOptions(scale: 3))
        #expect(wrong.dimensions.isEmpty)
        #expect(Self.unexplained(wrong).count == 6)
    }

    @Test("the rebuilt dimensions can be added to the drawing, marked as rebuilt")
    func applied() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        let page = try sheet.page()
        let recovery = page.recoveringDimensions()
        let drawing = page.drawing()
        let withDimensions = recovery.applied(to: drawing)
        #expect(withDimensions.counts.dimension == 6)
        #expect(withDimensions.entities.count == drawing.entities.count + 6)
        var rebuilt = 0
        for case .dimension(let dimension) in withDimensions.entities where dimension.rebuilt != nil
        {
            rebuilt += 1
        }
        #expect(rebuilt == 6)
        // Stored as they are read: none of the drawing's own entities is a dimension.
        #expect(drawing.counts.dimension == 0)
        #expect(recovery.rebuild.dimensions.count == 6)
        #expect(recovery.rebuild.scales.map(\.group) == ["sheet"])
    }

    @Test("a page with no dimensions gives none and no warnings")
    func nothing() throws {
        var sheet = DimensionSheet()
        sheet.line(20, 20, 120, 20)
        sheet.line(20, 20, 20, 80)
        sheet.text("TITLE", 30, 100)
        let recovery = try sheet.page().recoveringDimensions()
        #expect(recovery.dimensions.isEmpty)
        #expect(recovery.warnings.isEmpty)
        #expect(recovery.scale == nil)
    }

    @Test("the drawing is not scaled: it stays in millimetres on the paper")
    func notScaled() throws {
        var sheet = DimensionSheet()
        sheet.column(x: 30, y: 60, count: 6, scale: 2)
        let page = try sheet.page()
        let before = page.drawing()
        _ = page.recoveringDimensions()
        let after = page.drawing()
        #expect(before.entities.count == after.entities.count)
        let a = before.bounds
        let b = after.bounds
        #expect(a?.min.x == b?.min.x && a?.max.x == b?.max.x)
    }
}
