import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The text path where PDFKit is absent (tvOS), run here by leaving PDFKit out of the read.
@Suite("Without PDFKit")
struct WithoutPDFKitTests {
    @Test("a run keeps this reader's own text and is paired with nothing")
    func ownTextStands() throws {
        let url = try TextTests.appleWritten()
        let checked = try #require(try PDF.read(contentsOf: url).pages.first?.texts.first)
        let alone = try #require(
            try PDF.read(contentsOf: url, maximumPages: nil, crossCheck: false).pages.first?
                .texts.first)
        // With PDFKit the run is paired; without it, nothing is, and the text is this reader's own.
        #expect(checked.pdfKitText != nil)
        #expect(alone.pdfKitText == nil)
        #expect(alone.decoding != .pdfKit)
        #expect(alone.text == alone.ownText)
        #expect(alone.ownText == checked.ownText)
        #expect(alone.origin == checked.origin)
    }

    @Test("one character per operation is still joined into lines")
    func joining() throws {
        var content = "BT /F1 10 Tf "
        for (index, character) in "10,439".enumerated() {
            content += "1 0 0 1 \(100 + 5 * index) 100 Tm (\(character)) Tj "
        }
        content += "ET"
        var pdf = MiniPDF(content: content)
        pdf.objects = [MiniPDF.helvetica]
        pdf.resources = "<< /Font << /F1 {1} >> >>"
        let document = try PDF.read(
            contentsOf: try pdf.file(), maximumPages: nil, crossCheck: false)
        #expect(document.pages.first?.texts.map(\.text) == ["10,439"])
    }
}
