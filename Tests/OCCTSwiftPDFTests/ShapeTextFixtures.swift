import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Pages with text drawn as shapes, and a recogniser that needs no Vision.
enum ShapeTextFixtures {
    static let helveticaResources =
        "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>"

    /// A PDF file for `content`, read without the PDFKit cross-check.
    static func document(
        _ content: String, resources: String = "<< >>", mediaBox: String = "[0 0 612 792]",
        rotate: Int = 0
    ) throws -> PDF.Document {
        var pdf = MiniPDF(content: content, resources: resources)
        pdf.mediaBox = mediaBox
        pdf.rotate = rotate
        let url = try pdf.file()
        return try PDF.read(contentsOf: url, maximumPages: nil, crossCheck: false)
    }

    /// The first page of `document` as the file holds it, for rendering.
    static func cgPage(_ document: PDF.Document) throws -> CGPDFPage {
        let file = try #require(CGPDFDocument(document.url as CFURL))
        return try #require(file.page(at: 1))
    }

    /// The darkness (0 white, 1 black) of a pixel `x` from the left and `y` from the bottom.
    static func darkness(_ image: CGImage, x: Int, y: Int) -> Double {
        guard (0..<image.width).contains(x), (0..<image.height).contains(y),
            let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return 0 }
        let row = image.height - 1 - y
        return 1 - Double(bytes[row * image.bytesPerRow + x]) / 255
    }
}

/// A recogniser that needs no Vision: it reads the text it was told to, wherever the ink is.
///
/// Its box is where the ink is, optionally grown or turned, and it can report less confidence. It
/// stands in for Vision where a test is about the geometry round the recogniser.
final class InkRecogniser: TextRecogniser {
    var text: String
    var confidence = 1.0
    /// The box is this much taller and longer than the ink, as a fraction of the ink's height,
    /// on each side.
    var grow = 0.0
    /// The box is turned this many degrees about its centre.
    var turnDegrees = 0.0
    /// The number of images it was asked about.
    var calls = 0

    init(_ text: String) { self.text = text }

    func lines(in image: CGImage) throws -> [RecognisedLine] {
        calls += 1
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return []
        }
        var x0 = image.width
        var x1 = -1
        var y0 = image.height
        var y1 = -1
        for row in 0..<image.height {
            for column in 0..<image.width where bytes[row * image.bytesPerRow + column] < 128 {
                x0 = min(x0, column)
                x1 = max(x1, column)
                y0 = min(y0, row)
                y1 = max(y1, row)
            }
        }
        guard x1 >= x0 else { return [] }
        let width = Double(image.width)
        let height = Double(image.height)
        let inkHeight = Double(y1 - y0 + 1)
        let margin = grow * inkHeight
        let left = (Double(x0) - margin) / width
        let right = (Double(x1 + 1) + margin) / width
        let top = 1 - (Double(y0) - margin) / height
        let bottom = 1 - (Double(y1 + 1) + margin) / height
        var corners = [
            CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom),
            CGPoint(x: right, y: top), CGPoint(x: left, y: top),
        ]
        if turnDegrees != 0 {
            let centre = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
            let angle = turnDegrees * .pi / 180
            corners = corners.map { corner in
                // Turned in pixels, not in fractions, so the box stays a rectangle.
                let dx = (corner.x - centre.x) * width
                let dy = (corner.y - centre.y) * height
                let x = dx * cos(angle) - dy * sin(angle)
                let y = dx * sin(angle) + dy * cos(angle)
                return CGPoint(x: centre.x + x / width, y: centre.y + y / height)
            }
        }
        return [RecognisedLine(text: text, confidence: confidence, corners: corners)]
    }
}
