import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The grid that finds the shapes near a shape.
@Suite("Box grid")
struct BoxGridTests {
    static func near(_ grid: BoxGrid, _ rect: CGRect) -> [Int] {
        var seen: [Int] = []
        grid.forEach(near: rect) { seen.append($0) }
        return seen.sorted()
    }

    @Test("it gives the boxes that touch the cells a rectangle touches, each once")
    func finds() {
        let boxes = [
            CGRect(x: 0, y: 0, width: 3, height: 3),
            CGRect(x: 2, y: 2, width: 10, height: 10),
            CGRect(x: 100, y: 100, width: 1, height: 1),
        ]
        let grid = BoxGrid(boxes: boxes, cell: 2)
        #expect(Self.near(grid, CGRect(x: 2, y: 2, width: 1, height: 1)) == [0, 1])
        #expect(Self.near(grid, CGRect(x: 100, y: 100, width: 0.5, height: 0.5)) == [2])
        #expect(Self.near(grid, CGRect(x: 50, y: 50, width: 1, height: 1)).isEmpty)
        #expect(!grid.exceeded)
    }

    @Test("coordinates that are not finite or are enormous do not trap")
    func hostile() {
        let boxes = [
            CGRect(x: 1e300, y: 0, width: 1, height: 1),
            CGRect(x: Double.nan, y: 0, width: 1, height: 1),
            CGRect(x: -1e300, y: 1e300, width: 5, height: 5),
            CGRect(x: 0, y: 0, width: 2, height: 2),
        ]
        let grid = BoxGrid(boxes: boxes, cell: 2)
        #expect(Self.near(grid, CGRect(x: 0, y: 0, width: 1, height: 1)).contains(3))
        // And one box as wide as the grid is the work limit's to stop, not an endless loop.
        let huge = BoxGrid(
            boxes: [CGRect(x: -1e300, y: -1e300, width: 2e300, height: 2e300)], cell: 2)
        #expect(huge.exceeded)
        #expect(Self.near(huge, CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty)
    }

    @Test("it stops after the work limit, and says so")
    func limit() {
        let boxes = (0..<200).map { CGRect(x: Double($0), y: 0, width: 50, height: 50) }
        #expect(!BoxGrid(boxes: boxes, cell: 2).exceeded)
        #expect(BoxGrid(boxes: boxes, cell: 2, limit: 1_000).exceeded)
        // Grouping glyphs from them, the same.
        let pieces = boxes.map { ShapePiece(path: 0, subpath: 0, box: $0, filled: true) }
        #expect(ShapeTextPieces.glyphs(from: pieces) != nil)
        #expect(ShapeTextPieces.glyphs(from: pieces, limit: 1_000) == nil)
    }
}
