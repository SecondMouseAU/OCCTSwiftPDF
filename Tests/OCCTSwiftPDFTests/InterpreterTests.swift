import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Paths, transforms, Form XObjects and layers, on PDFs written by hand.
@Suite("Interpreter")
struct InterpreterTests {
    static func page(_ pdf: MiniPDF) throws -> PDF.Page {
        let document = try PDF.read(contentsOf: try pdf.file())
        return try #require(document.pages.first)
    }

    static func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    @Test("a line is placed by the transform, and its width scaled with it")
    func lineUnderTransform() throws {
        let page = try Self.page(MiniPDF(content: "q 2 0 0 2 10 20 cm 0 0 m 100 0 l S Q"))
        let path = try #require(page.paths.first)
        #expect(path.paint == .stroke)
        #expect(Self.close(path.subpaths[0].start, CGPoint(x: 10, y: 20)))
        #expect(path.subpaths[0].segments == [.line(to: CGPoint(x: 210, y: 20))])
        #expect(abs(path.lineWidth - 2) < 1e-9)
        #expect(page.kind == .vector)
    }

    @Test("a rectangle is a closed polyline in the drawing, in millimetres")
    func rectangle() throws {
        let page = try Self.page(MiniPDF(content: "72 72 144 72 re S"))
        let drawing = page.drawing()
        #expect(drawing.entities.count == 1)
        guard case .polyline(let vertices, let closed, _, _) = drawing.entities.first else {
            Issue.record("not a polyline")
            return
        }
        #expect(closed)
        #expect(vertices.count == 4)
        // One inch is 25.4 mm.
        #expect(abs(vertices[0].point.x - 25.4) < 1e-9 && abs(vertices[0].point.y - 25.4) < 1e-9)
        #expect(abs(vertices[2].point.x - 76.2) < 1e-9 && abs(vertices[2].point.y - 50.8) < 1e-9)
        #expect(drawing.insUnits == 4)
    }

    @Test("a circle drawn as four curves becomes four splines that fit as arcs near its radius")
    func circleBecomesArcs() throws {
        // The usual four-curve circle of radius 72 (one inch) about (200, 200).
        let k = 0.5522847498 * 72
        let content = """
            272 200 m 272 \(200 + k) \(200 + k) 272 200 272 c
            \(200 - k) 272 128 \(200 + k) 128 200 c
            128 \(200 - k) \(200 - k) 128 200 128 c
            \(200 + k) 128 272 \(200 - k) 272 200 c S
            """
        let drawing = try Self.page(MiniPDF(content: content)).drawing()
        #expect(drawing.counts.spline == 4)
        for entity in drawing.entities {
            let fit = try #require(entity.fitted(tolerance: 0.01))
            #expect(fit.deviation <= 0.01)
            for piece in fit.pieces {
                let segment = piece.segment
                #expect(segment.isArc)
                let chord = segment.start.distance(to: segment.end)
                let radius = chord / (2 * sin(abs(segment.sweep) / 2))
                // SwiftDXF's fit holds each piece within the tolerance of the curve, not the
                // radius: the two arcs per quarter come out about 25.29 mm, 0.44 percent short of
                // 25.4. Arc recovery for the ledger needs a direct test of the whole circle.
                #expect(abs(radius - 25.4) < 0.15, "radius \(radius)")
            }
        }
    }

    @Test("a Form XObject is followed with its matrix, and named in the source")
    func formXObject() throws {
        var pdf = MiniPDF(content: "q 1 0 0 1 100 50 cm /Fm0 Do Q")
        pdf.objects = [
            MiniPDF.stream(
                "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [2 0 0 2 0 0]",
                "0 0 m 10 0 l S")
        ]
        pdf.resources = "<< /XObject << /Fm0 {1} >> >>"
        let page = try Self.page(pdf)
        let path = try #require(page.paths.first)
        #expect(Self.close(path.subpaths[0].start, CGPoint(x: 100, y: 50)))
        #expect(path.subpaths[0].segments == [.line(to: CGPoint(x: 120, y: 50))])
        #expect(path.source.forms == ["Fm0#1"])
        #expect(page.formInvocations == 1)
        #expect(page.drawing().identities.first?.via == ["Fm0#1"])
    }

    @Test("marked content for an optional content group puts its paths on that layer")
    func layers() throws {
        var pdf = MiniPDF(
            content: "/OC /oc1 BDC 0 0 m 10 10 l S EMC /Span BMC 0 0 m 5 0 l S EMC")
        pdf.objects = ["<< /Type /OCG /Name (Dimensions) >>"]
        pdf.resources = "<< /Properties << /oc1 {1} >> >>"
        pdf.catalogExtra = "/OCProperties << /OCGs [{1}] /D << /ON [{1}] >> >>"
        let document = try PDF.read(contentsOf: try pdf.file())
        #expect(document.layers == ["Dimensions"])
        let page = try #require(document.pages.first)
        #expect(page.paths.map(\.layer) == ["Dimensions", nil])
        #expect(page.layers == ["Dimensions"])
        let drawing = page.drawing()
        #expect(drawing.layers.map(\.name) == ["0", "Dimensions"])
    }

    @Test("a path used only to clip is counted and not drawn")
    func clipOnly() throws {
        let page = try Self.page(MiniPDF(content: "0 0 100 100 re W n 0 0 m 10 0 l S"))
        #expect(page.paths.count == 1)
        #expect(page.clipPaths == 1)
    }

    @Test("an image over the page makes it raster; a small one leaves it vector")
    func classification() throws {
        let image = MiniPDF.stream(
            "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray "
                + "/BitsPerComponent 8", "\u{7F}")
        var scan = MiniPDF(content: "q 612 0 0 792 0 0 cm /Im0 Do Q")
        scan.objects = [image]
        scan.resources = "<< /XObject << /Im0 {1} >> >>"
        let scanned = try Self.page(scan)
        #expect(scanned.kind == .raster)
        #expect(abs(scanned.imageCoverage - 1) < 1e-9)

        var logo = MiniPDF(content: "q 100 0 0 50 500 700 cm /Im0 Do Q 0 0 m 300 300 l S")
        logo.objects = [image]
        logo.resources = "<< /XObject << /Im0 {1} >> >>"
        #expect(try Self.page(logo).kind == .vector)
    }

    @Test("a page turned by /Rotate is drawn upright")
    func rotatedPage() throws {
        var pdf = MiniPDF(content: "0 0 m 72 0 l S")
        pdf.rotate = 90
        let page = try Self.page(pdf)
        let drawing = page.drawing()
        guard case .line(let a, let b, _, _) = drawing.entities.first else {
            Issue.record("not a line")
            return
        }
        // Turned a quarter clockwise, the page's bottom edge is its left edge, running down.
        #expect(abs(a.x) < 1e-9 && abs(a.y - 612 * 25.4 / 72) < 1e-9)
        #expect(abs(b.x) < 1e-9 && abs(b.y - (612 - 72) * 25.4 / 72) < 1e-9)
    }

    @Test("colours are read for gray, RGB and CMYK, and carried into the drawing")
    func colours() throws {
        let page = try Self.page(
            MiniPDF(
                content: """
                    0.2 0.4 0.6 RG 0 0 m 10 0 l S
                    0.5 G 0 5 m 10 5 l S
                    0 1 1 0 K 0 10 m 10 10 l S
                    0.25 g 0 0 5 5 re f
                    """))
        func same(_ a: PDF.Colour, _ r: Double, _ g: Double, _ b: Double) -> Bool {
            abs(a.red - r) < 1e-9 && abs(a.green - g) < 1e-9 && abs(a.blue - b) < 1e-9
        }
        #expect(same(page.paths[0].strokeColour, 0.2, 0.4, 0.6))
        #expect(same(page.paths[1].strokeColour, 0.5, 0.5, 0.5))
        #expect(same(page.paths[2].strokeColour, 1, 0, 0))
        #expect(same(page.paths[3].fillColour, 0.25, 0.25, 0.25))
        guard case .line(_, _, _, let red) = page.drawing().entities[2] else {
            Issue.record("not a line")
            return
        }
        #expect(red == 1)
    }

    @Test("each piece of one painted path has its own identity")
    func pieceIdentities() throws {
        let page = try Self.page(MiniPDF(content: "0 0 m 10 0 l 0 5 m 10 5 l S"))
        let ids = page.drawing().identities.map(\.locator)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { $0.hasPrefix("p1:op") })
    }

    @Test("an unbalanced Form XObject does not leak its state or layer onto the page")
    func unbalancedForm() throws {
        var pdf = MiniPDF(content: "/Fm0 Do 0 0 m 10 0 l S")
        pdf.objects = [
            MiniPDF.stream(
                "/Type /XObject /Subtype /Form /BBox [0 0 100 100]",
                "Q Q 5 0 0 5 0 0 cm /OC /oc1 BDC 0 0 m 1 0 l S"),
            "<< /Type /OCG /Name (Inside) >>",
        ]
        pdf.resources = "<< /XObject << /Fm0 {1} >> /Properties << /oc1 {2} >> >>"
        let page = try Self.page(pdf)
        #expect(page.paths.count == 2)
        #expect(page.paths[0].layer == "Inside")
        let after = page.paths[1]
        #expect(after.layer == nil)
        #expect(after.subpaths[0].segments == [.line(to: CGPoint(x: 10, y: 0))])
    }

    @Test("an inline image counts towards the page's image coverage")
    func inlineImage() throws {
        let page = try Self.page(
            MiniPDF(content: "q 612 0 0 792 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 ID \u{7F} EI Q"))
        #expect(page.inlineImages == 1)
        #expect(page.kind == .raster)
    }

    @Test("a form's extra Q and EMC do not pop the page's saved state or layer")
    func formCannotPopPage() throws {
        var pdf = MiniPDF(
            content: "/OC /oc1 BDC q 2 0 0 2 0 0 cm /Fm0 Do Q 0 0 m 10 0 l S EMC")
        pdf.objects = [
            MiniPDF.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "Q EMC EMC"),
            "<< /Type /OCG /Name (Page) >>",
        ]
        pdf.resources = "<< /XObject << /Fm0 {1} >> /Properties << /oc1 {2} >> >>"
        let path = try #require(try Self.page(pdf).paths.first)
        #expect(path.subpaths[0].segments == [.line(to: CGPoint(x: 10, y: 0))])
        #expect(path.layer == "Page")
    }

    @Test("colours follow the space set by cs and CS: device, ICC-based and separation")
    func colourSpaces() throws {
        var pdf = MiniPDF(
            content: """
                /DeviceRGB CS 1 0 0 SC 0 0 m 10 0 l S
                /Ink cs 1 sc 0 0 5 5 re f
                /Icc CS 0 0 1 SC 0 5 m 10 5 l S
                """)
        pdf.objects = [
            "[/Separation /Black /DeviceGray {2}]",
            "<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>",
            "[/ICCBased {4}]",
            MiniPDF.stream("/N 3", "x"),
        ]
        pdf.resources = "<< /ColorSpace << /Ink {1} /Icc {3} >> >>"
        let page = try Self.page(pdf)
        func same(_ a: PDF.Colour, _ r: Double, _ g: Double, _ b: Double) -> Bool {
            abs(a.red - r) < 1e-9 && abs(a.green - g) < 1e-9 && abs(a.blue - b) < 1e-9
        }
        #expect(same(page.paths[0].strokeColour, 1, 0, 0))
        // A full tint of ink is black, not white.
        #expect(same(page.paths[1].fillColour, 0, 0, 0))
        #expect(same(page.paths[2].strokeColour, 0, 0, 1))
    }
}
