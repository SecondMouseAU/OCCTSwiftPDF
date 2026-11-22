import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The text path where the SDK has no PDFKit (older tvOS SDKs), run here by leaving PDFKit out of
/// the read.
@Suite("Without PDFKit")
struct WithoutPDFKitTests {
    /// The first page of the PDF at `url`, read with or without the PDFKit cross-check.
    static func page(_ url: URL, crossCheck: Bool) throws -> PDF.Page {
        let document = try PDF.read(contentsOf: url, maximumPages: nil, crossCheck: crossCheck)
        return try #require(document.pages.first)
    }

    /// A one-page PDF with `content` shown in `font`, as a hand-built file.
    static func file(_ content: String, font: String = MiniPDF.helvetica, extra: [String] = [])
        throws -> URL
    {
        var pdf = MiniPDF(content: content)
        pdf.objects = [font] + extra
        pdf.resources = "<< /Font << /F1 {1} >> >>"
        return try pdf.file()
    }

    @Test("a run keeps this reader's own text and is paired with nothing")
    func ownTextStands() throws {
        let url = try TextTests.appleWritten()
        let checked = try #require(try Self.page(url, crossCheck: true).texts.first)
        let alone = try #require(try Self.page(url, crossCheck: false).texts.first)
        // With PDFKit the run is paired; without it, nothing is, and the text is this reader's own.
        #expect(checked.pdfKitText == "M26x5.0mm")
        #expect(alone.pdfKitText == nil)
        #expect(alone.decoding != .pdfKit)
        #expect(alone.ownText?.filter { !$0.isWhitespace } == "M26x5.0mm")
        #expect(alone.text == alone.ownText)
        #expect(alone.origin == checked.origin)
    }

    @Test("a guessed reading stands, as there is nothing to contradict it")
    func guessStands() throws {
        let url = try Self.file(
            "BT /F1 10 Tf 100 100 Td (M26) Tj ET",
            font: "<< /Type /Font /Subtype /TrueType /BaseFont /Symbolic /FirstChar 32 >>")
        let run = try #require(try Self.page(url, crossCheck: false).texts.first)
        #expect(run.text == "M26")
        #expect(run.decoding == .asciiGuess)
        #expect(run.pdfKitText == nil)
    }

    @Test("a run this reader cannot decode stays without text, with no PDFKit to fill it")
    func undecodableStaysEmpty() throws {
        let font = """
            << /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H \
            /DescendantFonts [{2}] >>
            """
        let descendant = """
            << /Type /Font /Subtype /CIDFontType2 /BaseFont /X \
            /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> >>
            """
        let url = try Self.file(
            "BT /F1 10 Tf 100 100 Td <00030004> Tj ET", font: font, extra: [descendant])
        let run = try #require(try Self.page(url, crossCheck: false).texts.first)
        #expect(run.text == nil)
        #expect(run.decoding == .none)
        #expect(run.codeCount == 2)
    }

    @Test("one character per operation is still joined into lines")
    func joining() throws {
        var content = "BT /F1 10 Tf "
        for (index, character) in "10,439".enumerated() {
            content += "1 0 0 1 \(100 + 5 * index) 100 Tm (\(character)) Tj "
        }
        content += "ET"
        let page = try Self.page(try Self.file(content), crossCheck: false)
        #expect(page.texts.map(\.text) == ["10,439"])
        #expect(page.texts.allSatisfy { $0.pdfKitText == nil })
    }
}
