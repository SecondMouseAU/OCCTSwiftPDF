import Foundation
import Testing

@testable import OCCTSwiftPDF

/// ToUnicode CMaps, including the forms writers produce that the specification does not.
@Suite("CMap")
struct CMapTests {
    static func map(_ text: String) -> CMap { CMap(Data(text.utf8)) }

    @Test("bfchar, bfrange with a start and bfrange with an array")
    func ranges() {
        let cmap = Self.map(
            """
            1 begincodespacerange <00> <FF> endcodespacerange
            1 beginbfchar <01> <0041> endbfchar
            2 beginbfrange <10> <12> <0030> <20> <21> [<0058> <0059>] endbfrange
            """)
        #expect(cmap.string(for: 0x01) == "A")
        #expect(cmap.string(for: 0x11) == "1")
        #expect(cmap.string(for: 0x21) == "Y")
        #expect(cmap.string(for: 0x22) == nil)
    }

    @Test("a one-byte target is that character, not an empty string")
    func oneByteTarget() {
        let cmap = Self.map("1 beginbfchar <05> <35> endbfchar")
        #expect(cmap.string(for: 0x05) == "5")
    }

    @Test("a glyph-name target is decoded and does not upset the entries after it")
    func nameTarget() {
        let cmap = Self.map("3 beginbfchar <01> /space <02> /zero <03> <0041> endbfchar")
        #expect(cmap.string(for: 0x01) == " ")
        #expect(cmap.string(for: 0x02) == "0")
        #expect(cmap.string(for: 0x03) == "A")
    }
}
