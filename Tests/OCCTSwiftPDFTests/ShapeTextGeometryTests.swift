import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Finding the lines of shapes that might be text, and rendering them upright, without Vision.
@Suite("Shape text geometry")
struct ShapeTextGeometryTests {
    static func found(_ content: String, rotate: Int = 0) throws -> (
        page: PDF.Page, found: ShapeTextRegions.Found
    ) {
        let document = try ShapeTextFixtures.document(content, rotate: rotate)
        let page = try #require(document.pages.first)
        return (page, ShapeTextRegions.find(in: page, options: PDF.ShapeTextOptions()))
    }

    @Test("a line of filled outlines is one region, measured from the shapes")
    func filledLine() throws {
        let text = OutlineText.drawn("10,439", at: CGPoint(x: 100, y: 100))
        let (_, found) = try Self.found(text.content)
        let region = try #require(found.regions.first)
        #expect(found.regions.count == 1)
        // One glyph each for 1, 0, the comma, 4, 3 and 9.
        #expect(region.glyphs == 6)
        #expect(!region.mostlyStroked)
        #expect(abs(region.angleDegrees) < 0.5)
        #expect(abs(region.origin.x - text.ink.minX) < 0.1)
        #expect(abs(region.origin.y - text.ink.minY) < 0.1)
        // The baseline is where the digits stand, above the bottom of the comma.
        #expect(abs(region.origin.y + region.baseline - 100) < 0.1)
        #expect(region.baseline > 1)
        #expect(abs(region.length - text.ink.width) < 0.1)
        #expect(abs(region.height - text.ink.height) < 0.1)
    }

    @Test("the hole of an O or an 8 is part of its glyph, not another")
    func holesAreNotGlyphs() throws {
        let text = OutlineText.drawn("0O8B", at: CGPoint(x: 100, y: 100))
        let (page, found) = try Self.found(text.content)
        // Each of these is one path of two or three subpaths.
        #expect(page.paths.reduce(0) { $0 + $1.subpaths.count } > 4)
        #expect(found.regions.count == 1)
        #expect(found.regions.first?.glyphs == 4)
    }

    @Test(
        "the baseline is where most glyphs stand: descenders and floating dots do not move it",
        arguments: ["filigree, gypsy", "Jilji 1,5", "ii;ii"])
    func baseline(string: String) throws {
        let text = OutlineText.drawn(string, at: CGPoint(x: 100, y: 100))
        let (_, found) = try Self.found(text.content)
        let region = try #require(found.regions.first)
        #expect(abs(region.origin.y + region.baseline - 100) < 0.25, "\(string)")
    }

    @Test("hollow outlines (stroked) are found as strokes")
    func strokedLine() throws {
        let text = OutlineText.drawn("SCALE 1:50", at: CGPoint(x: 100, y: 100), stroke: true)
        let (_, found) = try Self.found(text.content)
        let region = try #require(found.regions.first)
        #expect(found.regions.count == 1)
        #expect(region.mostlyStroked)
        // The stroke's own width widens the box a little.
        #expect(abs(region.length - text.ink.width) < 0.5)
    }

    @Test("two lines of text are two regions, and a gap along a line cuts it")
    func lines() throws {
        let first = OutlineText.drawn("BALISE", at: CGPoint(x: 100, y: 100))
        let second = OutlineText.drawn("ID PLATE", at: CGPoint(x: 100, y: 86))
        let far = OutlineText.drawn("DETAIL", at: CGPoint(x: 300, y: 100))
        let (_, found) = try Self.found(first.content + second.content + far.content)
        #expect(found.regions.count == 3)
    }

    @Test(
        "the reading direction is found from the shapes",
        arguments: [90.0, 30.0, -45.0])
    func direction(degrees: Double) throws {
        let text = OutlineText.drawn(
            "SECTION", at: CGPoint(x: 300, y: 300), rotationDegrees: degrees)
        let (_, found) = try Self.found(text.content)
        let region = try #require(found.regions.first)
        #expect(found.regions.count == 1)
        let expected = (degrees + 360).truncatingRemainder(dividingBy: 360)
        var error = abs(region.angleDegrees - expected)
        if error > 180 { error = 360 - error }
        // A line along the page's y axis can be read either way up; the other directions are
        // from the principal axis, read left to right.
        if abs(degrees) == 90 || degrees == 270 { error = min(error, abs(error - 180)) }
        #expect(error < 3, "found \(region.angleDegrees), drawn \(expected)")
        #expect(region.glyphs == 7)
        // The box is as long as the text is, along its own direction.
        #expect(abs(region.length - OutlineText.drawn("SECTION", at: .zero).ink.width) < 0.5)
    }

    @Test("a line of one glyph, a long shape and a page-sized one are not regions")
    func notRegions() throws {
        let single = OutlineText.drawn("A", at: CGPoint(x: 100, y: 100))
        var content = single.content
        content += "0 0 300 300 re f\n"
        let (_, found) = try Self.found(content)
        #expect(found.regions.isEmpty)
        #expect(found.tooSmall >= 1)
        // The A's outline and hole are one glyph; the big square is not a piece at all.
        #expect(found.shapes == 2)
    }

    @Test("shapes so many over one another that grouping them takes too long are left alone")
    func workLimit() throws {
        // Four hundred squares 40 units across, each over its neighbours.
        var content = "0.3 w\n"
        for row in 0..<20 {
            for column in 0..<20 {
                content += "\(20 + 3 * column) \(20 + 3 * row) 40 40 re S\n"
            }
        }
        let document = try ShapeTextFixtures.document(content)
        let page = try #require(document.pages.first)
        let options = PDF.ShapeTextOptions()
        let free = ShapeTextRegions.find(in: page, options: options)
        #expect(free.shapes == 400)
        #expect(free.shapesInDenseBlobs == 0)
        // Given too little work to group them, they are counted with the dense blobs.
        let limited = ShapeTextRegions.find(in: page, options: options, workLimit: 20_000)
        #expect(limited.shapes == 400)
        #expect(limited.shapesInDenseBlobs == 400)
        #expect(limited.regions.isEmpty)
    }

    @Test("a dense field of short strokes is left alone")
    func denseBlob() throws {
        var content = "0.2 w\n"
        for row in 0..<80 {
            for column in 0..<80 {
                let x = 20 + 3 * column
                let y = 20 + 3 * row
                content += "\(x) \(y) m \(x + 2) \(y + 2) l S\n"
            }
        }
        let (_, found) = try Self.found(content)
        #expect(found.regions.isEmpty)
        #expect(found.shapesInDenseBlobs == 6_400)
    }

    // MARK: Rendering

    /// An L (a stem and a foot) drawn turned `degrees` about `origin`, as content operators.
    static func ell(at origin: CGPoint, degrees: Double) -> String {
        let outline: [(Double, Double)] = [(0, 0), (6, 0), (6, 2), (2, 2), (2, 10), (0, 10)]
        let angle = degrees * .pi / 180
        var out = ""
        let (ox, oy) = (Double(origin.x), Double(origin.y))
        for (index, point) in outline.enumerated() {
            let turnedX = point.0 * cos(angle) - point.1 * sin(angle)
            let turnedY = point.0 * sin(angle) + point.1 * cos(angle)
            out += "\(ox + turnedX) \(oy + turnedY) \(index == 0 ? "m" : "l")\n"
        }
        return out + "h f\n"
    }

    @Test(
        "a crop shows the shapes upright, whichever way they are turned and however the page is",
        arguments: [0.0, 90.0, 30.0, 180.0], [0, 90])
    func cropIsUpright(degrees: Double, pageRotation: Int) throws {
        let origin = CGPoint(x: 250, y: 180)
        let document = try ShapeTextFixtures.document(
            Self.ell(at: origin, degrees: degrees), mediaBox: "[100 100 400 300]",
            rotate: pageRotation)
        let source = try ShapeTextFixtures.cgPage(document)
        let angle = degrees * .pi / 180
        let region = ShapeTextRegion(
            direction: CGPoint(x: cos(angle), y: sin(angle)), origin: origin, length: 6,
            height: 10, glyphs: 2, mostlyStroked: false, canReverse: false, paths: [0])
        let scale = 8.0
        let padding = 3.0
        let area = region.bounds.insetBy(dx: -20, dy: -20)
        let tile = try #require(ShapeTextRenderer.render(source, area: area, scale: scale))
        let crop = try #require(tile.crop(region, padding: padding))
        #expect(crop.image.width == Int(((6 + 2 * padding) * scale).rounded(.up)))
        #expect(crop.image.height == Int(((10 + 2 * padding) * scale).rounded(.up)))
        func at(_ a: Double, _ b: Double) -> Double {
            ShapeTextFixtures.darkness(
                crop.image, x: Int((padding + a) * scale), y: Int((padding + b) * scale))
        }
        // The stem at the left, the foot along the bottom, and white where the L is not.
        #expect(at(1, 5) > 0.9)
        #expect(at(1, 9) > 0.9)
        #expect(at(5, 1) > 0.9)
        #expect(at(5, 6) < 0.1)
        #expect(at(4, 9) < 0.1)
        // The margin is white.
        #expect(ShapeTextFixtures.darkness(crop.image, x: 2, y: 2) < 0.1)
        // And the crop's frame maps back to the page: the stem's middle.
        let normalised = CGPoint(
            x: (padding + 1) * scale / Double(crop.image.width),
            y: (padding + 5) * scale / Double(crop.image.height))
        let frame = crop.frame(normalised)
        #expect(abs(frame.a - 1) < 0.1 && abs(frame.b - 5) < 0.1)
    }

    @Test("the same crop read the other way round is the shapes upside down")
    func reversedCrop() throws {
        let origin = CGPoint(x: 250, y: 180)
        let document = try ShapeTextFixtures.document(Self.ell(at: origin, degrees: 0))
        let source = try ShapeTextFixtures.cgPage(document)
        let region = ShapeTextRegion(
            direction: CGPoint(x: 1, y: 0), origin: origin, length: 6, height: 10, glyphs: 2,
            mostlyStroked: false, canReverse: true, paths: [0])
        let scale = 8.0
        let tile = try #require(
            ShapeTextRenderer.render(
                source, area: region.bounds.insetBy(dx: -20, dy: -20), scale: scale))
        let crop = try #require(tile.crop(region.reversed, padding: 3))
        func at(_ a: Double, _ b: Double) -> Double {
            ShapeTextFixtures.darkness(crop.image, x: Int((3 + a) * scale), y: Int((3 + b) * scale))
        }
        // Stem at the right, foot along the top.
        #expect(at(5, 5) > 0.9)
        #expect(at(1, 9) > 0.9)
        #expect(at(1, 4) < 0.1)
    }

    @Test("a region's scale makes its height the wanted pixels, in shared steps")
    func scales() {
        func region(height: Double, length: Double = 30) -> ShapeTextRegion {
            ShapeTextRegion(
                direction: CGPoint(x: 1, y: 0), origin: .zero, length: length, height: height,
                glyphs: 5, mostlyStroked: false, canReverse: false, paths: [0])
        }
        let eight = ShapeTextRenderer.scale(for: region(height: 8), glyphPixels: 40)
        #expect(abs(8 * eight - 40) / 40 < 0.2)
        // Regions of nearly the same height share a scale, so a tile.
        #expect(ShapeTextRenderer.scale(for: region(height: 7.9), glyphPixels: 40) == eight)
        // A long line is rendered smaller rather than past the crop limit.
        let long = ShapeTextRenderer.scale(for: region(height: 8, length: 2_000), glyphPixels: 40)
        #expect(2_000 * long <= 4_096)
    }
}
