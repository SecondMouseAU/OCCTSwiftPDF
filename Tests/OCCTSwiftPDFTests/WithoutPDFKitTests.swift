import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The text path on tvOS, where PDFKit is not used, run here by leaving PDFKit out of the read.
@Suite("Without PDFKit")
struct WithoutPDFKitTests {
    /// The first page of the PDF at `url`, read with or without the PDFKit cross-check.
    static func page(_ url: URL, crossCheck: Bool) throws -> PDF.Page {
        let document = try PDF.read(contentsOf: url, maximumPages: nil, crossCheck: crossCheck)
        return try #require(document.pages.first)
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

    /// A non-embedded Adobe-Japan1 font showing CIDs 34 to 36, which are "ABC".
    ///
    /// This reader has no table from CIDs to characters, but PDFKit does, as for the Hiragino fonts
    /// in the corpus.
    static func japan1File() throws -> URL {
        let font = """
            << /Type /Font /Subtype /Type0 /BaseFont /HiraginoSans-W3 /Encoding /Identity-H \
            /DescendantFonts [{2}] >>
            """
        let descendant = """
            << /Type /Font /Subtype /CIDFontType0 /BaseFont /HiraginoSans-W3 \
            /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 6 >> \
            /DW 1000 /FontDescriptor {3} >>
            """
        let descriptor = """
            << /Type /FontDescriptor /FontName /HiraginoSans-W3 /Flags 4 \
            /FontBBox [-100 -200 1100 900] /ItalicAngle 0 /Ascent 880 /Descent -120 \
            /CapHeight 700 /StemV 80 >>
            """
        return try TextTests.pdf(
            "BT /F1 12 Tf 100 100 Td <002200230024> Tj ET", font: font,
            extra: [descendant, descriptor]
        ).file()
    }

    /// Whether PDFKit on this machine reads ``japan1File()``, which depends on its system fonts.
    static let pdfKitReadsJapan1: Bool = {
        guard let url = try? japan1File() else { return false }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return (try? page(url, crossCheck: true).texts.first?.pdfKitText) == "ABC"
    }()

    @Test("a run only PDFKit could read has no text without it, and is counted as skipped")
    func unreadableRunHasNoText() throws {
        let page = try Self.page(try Self.japan1File(), crossCheck: false)
        let run = try #require(page.texts.first)
        #expect(run.text == nil)
        #expect(run.pdfKitText == nil)
        #expect(run.decoding == .none)
        #expect(run.codeCount == 3)
        let drawing = page.drawing()
        #expect(drawing.skipped["TEXT"] == 1)
        #expect(drawing.counts.text == 0)
    }

    @Test(
        "PDFKit reads that run when the cross-check is on",
        .enabled(
            if: WithoutPDFKitTests.pdfKitReadsJapan1,
            "PDFKit does not read the Adobe-Japan1 fixture on this machine"))
    func pdfKitReadsIt() throws {
        let page = try Self.page(try Self.japan1File(), crossCheck: true)
        let run = try #require(page.texts.first)
        #expect(run.ownText == nil)
        #expect(run.text == "ABC")
        #expect(run.decoding == .pdfKit)
        #expect(page.drawing().counts.text == 1)
    }

    @Test("one character per operation is still joined into lines")
    func joining() throws {
        var content = "BT /F1 10 Tf "
        for (index, character) in "10,439".enumerated() {
            content += "1 0 0 1 \(100 + 5 * index) 100 Tm (\(character)) Tj "
        }
        content += "ET"
        let url = try TextTests.pdf(content).file()
        let page = try Self.page(url, crossCheck: false)
        #expect(page.texts.map(\.text) == ["10,439"])
        #expect(page.texts.allSatisfy { $0.pdfKitText == nil })
    }
}
