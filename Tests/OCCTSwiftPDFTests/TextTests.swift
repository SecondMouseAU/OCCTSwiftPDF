import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Text placement, decoding and joining.
@Suite("Text")
struct TextTests {
    static func page(_ content: String, font: String = MiniPDF.helvetica, extra: [String] = [])
        throws -> PDF.Page
    {
        var pdf = MiniPDF(content: content)
        pdf.objects = [font] + extra
        pdf.resources = "<< /Font << /F1 {1} >> >>"
        return try InterpreterTests.page(pdf)
    }

    @Test("a run's origin, size, direction and width come from the text and graphics state")
    func placement() throws {
        let page = try Self.page("q 2 0 0 2 0 0 cm BT /F1 10 Tf 0 1 -1 0 150 50 Tm (R5) Tj ET Q")
        let run = try #require(page.texts.first)
        #expect(run.text == "R5")
        #expect(run.decoding == .simpleEncoding)
        #expect(InterpreterTests.close(run.origin, CGPoint(x: 300, y: 100)))
        #expect(abs(run.rotationDeg - 90) < 1e-9)
        #expect(abs(run.height - 20) < 1e-9)
        // Two characters of half an em at 10, doubled by the transform.
        #expect(abs(run.width - 20) < 1e-9)
    }

    @Test("a TJ number moves the next character by thousandths of the size")
    func kerning() throws {
        let page = try Self.page("BT /F1 10 Tf 100 100 Td [(A) -1000 (B)] TJ ET")
        let run = try #require(page.texts.first)
        #expect(run.text == "AB")
        #expect(abs(run.width - 20) < 1e-9)
    }

    @Test("one character per operation is joined into one run")
    func joining() throws {
        var content = "BT /F1 10 Tf "
        for (index, character) in "10,439".enumerated() {
            content += "1 0 0 1 \(100 + 5 * index) 100 Tm (\(character)) Tj "
        }
        content += "1 0 0 1 100 300 Tm (559) Tj ET"
        let page = try Self.page(content)
        #expect(page.texts.map(\.text) == ["10,439", "559"])
        #expect(page.texts.first?.parts.count == 5)
        #expect(abs((page.texts.first?.width ?? 0) - 30) < 1e-9)
    }

    @Test("invisible text is flagged and kept in the drawing")
    func invisible() throws {
        let page = try Self.page("BT /F1 10 Tf 3 Tr 100 100 Td (1,956) Tj ET")
        #expect(page.texts.first?.isInvisible == true)
        #expect(page.drawing().counts.text == 1)
    }

    @Test("a font with a Shift-JIS CMap is decoded as Shift-JIS")
    func shiftJIS() throws {
        let font = """
            << /Type /Font /Subtype /Type0 /BaseFont /MS-Gothic /Encoding /90ms-RKSJ-H \
            /DescendantFonts [{2}] >>
            """
        let descendant = """
            << /Type /Font /Subtype /CIDFontType0 /BaseFont /MS-Gothic \
            /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /DW 1000 >>
            """
        // 形式 (8C60 8EAE in Shift-JIS) then the ASCII value 2,438.
        let page = try Self.page(
            "BT /F1 10 Tf 100 100 Td <8C608EAE> Tj 0 -20 Td (2,438) Tj ET", font: font,
            extra: [descendant])
        #expect(page.texts.map(\.text) == ["形式", "2,438"])
        #expect(page.texts.allSatisfy { $0.decoding == .shiftJIS })
        // Double-byte characters are an em wide, single-byte ones half an em.
        #expect(abs(page.texts[0].width - 20) < 1e-9)
        #expect(abs(page.texts[1].width - 25) < 1e-9)
    }

    @Test("a ToUnicode map decodes codes the font gives no other way back from")
    func toUnicode() throws {
        let cmap = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            2 beginbfchar <0003> <2300> <0004> <0035> endbfchar
            1 beginbfrange <0010> <0012> <0041> endbfrange
            endcmap end end
            """
        let font = """
            << /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H \
            /DescendantFonts [{2}] /ToUnicode {3} >>
            """
        let descendant = """
            << /Type /Font /Subtype /CIDFontType2 /BaseFont /X \
            /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> \
            /W [3 [600 500]] >>
            """
        let page = try Self.page(
            "BT /F1 10 Tf 100 100 Td <000300040010001100120099> Tj ET", font: font,
            extra: [descendant, MiniPDF.stream("", cmap)])
        let run = try #require(page.texts.first)
        // ⌀5ABC, with the unmapped last code left out.
        #expect(run.text == "\u{2300}5ABC")
        #expect(run.decoding == .toUnicode)
    }

    @Test("text written by Apple's PDF writer decodes the same by this reader and by PDFKit")
    func applePDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCCTSwiftPDFTests-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "M26 x 5.0mm", attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 72, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let page = try #require(try PDF.read(contentsOf: url).pages.first)
        let run = try #require(page.texts.first)
        #expect(run.ownText?.filter { !$0.isWhitespace } == "M26x5.0mm")
        #expect(run.pdfKitText == "M26x5.0mm")
        #expect(abs(run.origin.x - 72) < 1e-6 && abs(run.origin.y - 100) < 1e-6)
    }
}
