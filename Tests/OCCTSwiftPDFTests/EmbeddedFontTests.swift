import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Text read from an embedded TrueType font's own `cmap`, for fonts that give no `ToUnicode` map.
@Suite("Embedded font")
struct EmbeddedFontTests {
    // MARK: Building fonts by hand

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value & 0xFFFF) }

    /// A format 12 subtable: groups of `(first code, last code, first glyph)`.
    static func format12(_ groups: [(Int, Int, Int)]) -> [UInt8] {
        let body = groups.flatMap { be32($0.0) + be32($0.1) + be32($0.2) }
        return be16(12) + be16(0) + be32(16 + body.count) + be32(0) + be32(groups.count) + body
    }

    /// A format 4 subtable: segments of `(first, last, idDelta, idRangeOffset)`, then the glyph
    /// index array the range offsets point into.
    static func format4(_ segments: [(Int, Int, Int, Int)], glyphArray: [Int] = []) -> [UInt8] {
        let tables =
            segments.flatMap { be16($0.1) } + be16(0) + segments.flatMap { be16($0.0) }
            + segments.flatMap { be16($0.2 & 0xFFFF) } + segments.flatMap { be16($0.3) }
            + glyphArray.flatMap { be16($0) }
        let header = be16(4) + be16(14 + tables.count) + be16(0) + be16(segments.count * 2)
        return header + be16(0) + be16(0) + be16(0) + tables
    }

    /// A TrueType font that has only a `cmap` table.
    ///
    /// `subtables` are `(platform, encoding, subtable)`. Every byte is below 0x80 when the
    /// subtables' are, so `MiniPDF` can carry the font.
    static func font(_ subtables: [(Int, Int, [UInt8])]) -> Data {
        var offset = 4 + 8 * subtables.count
        var records: [UInt8] = []
        var bodies: [UInt8] = []
        for (platform, encoding, subtable) in subtables {
            records += be16(platform) + be16(encoding) + be32(offset)
            bodies += subtable
            offset += subtable.count
        }
        let cmap = be16(0) + be16(subtables.count) + records + bodies
        let header =
            be32(0x0001_0000) + be16(1) + be16(0) + be16(0) + be16(0)
            + Array("cmap".utf8) + be32(0) + be32(28) + be32(cmap.count)
        return Data(header + cmap)
    }

    static func characters(_ subtables: [(Int, Int, [UInt8])]) -> FontCharacters? {
        FontCharacters(font(subtables))
    }

    /// 'A' to 'C' on glyphs 1 to 3.
    static let letters = [(3, 10, format12([(0x41, 0x43, 1)]))]

    // MARK: The cmap table

    @Test("format 12 maps groups of code points to consecutive glyphs, and the lowest code wins")
    func format12Groups() throws {
        let characters = try #require(
            Self.characters([(3, 10, Self.format12([(0x41, 0x43, 1), (0x2300, 0x2300, 10)]))]))
        #expect(characters.scalar(forGlyph: 1) == "A")
        #expect(characters.scalar(forGlyph: 3) == "C")
        #expect(characters.scalar(forGlyph: 10) == "\u{2300}")
        #expect(characters.scalar(forGlyph: 4) == nil)

        // A glyph that is both a space and a no-break space reads as the space; control codes are
        // not text.
        let spaces = try #require(
            Self.characters(
                [(3, 10, Self.format12([(0x20, 0x20, 5), (0xA0, 0xA0, 5), (0x01, 0x01, 6)]))]))
        #expect(spaces.scalar(forGlyph: 5) == " ")
        #expect(spaces.scalar(forGlyph: 6) == nil)
    }

    @Test("format 4 maps by delta, and through the glyph index array")
    func format4Segments() throws {
        // 'A' to 'C' on glyphs 1 to 3 by delta; 'X' to 'Z' through the array, where 0 means none
        // and a glyph is the array's value plus the delta (offset 4 from the segment's own entry
        // lands on the array's first element); and the closing 0xFFFF segment.
        let subtable = Self.format4(
            [(0x41, 0x43, 1 - 0x41, 0), (0x58, 0x5A, 10, 4), (0xFFFF, 0xFFFF, 1, 0)],
            glyphArray: [20, 0, 22])
        let characters = try #require(Self.characters([(3, 1, subtable)]))
        #expect(characters.scalar(forGlyph: 1) == "A")
        #expect(characters.scalar(forGlyph: 2) == "B")
        #expect(characters.scalar(forGlyph: 30) == "X")
        // The array's 0 is "no glyph", not glyph 0 plus the delta.
        #expect(characters.scalar(forGlyph: 10) == nil)
        #expect(characters.scalar(forGlyph: 32) == "Z")
        #expect(characters.scalar(forGlyph: 31) == nil)
    }

    @Test("only the Unicode platform and Windows Unicode encodings are read")
    func unicodeOnly() {
        let subtable = Self.format12([(0x41, 0x41, 1)])
        // Macintosh, and Windows symbol, are not Unicode.
        #expect(Self.characters([(1, 0, subtable)]) == nil)
        #expect(Self.characters([(3, 0, subtable)]) == nil)
        #expect(Self.characters([(0, 3, subtable)]) != nil)
    }

    @Test("a damaged font gives nothing, or what is really there, and does not crash or run on")
    func damagedFonts() {
        let good = Self.font(Self.letters)
        #expect(FontCharacters(Data()) == nil)
        #expect(FontCharacters(good.prefix(20)) == nil)
        #expect(FontCharacters(Data(repeating: 0x7F, count: 64)) == nil)

        // A subtable cut short in its only group, and a table offset past the end.
        #expect(FontCharacters(good.prefix(good.count - 8)) == nil)
        var farTable = [UInt8](good)
        farTable.replaceSubrange(20..<24, with: Self.be32(0x7FFF_FFF0))
        #expect(FontCharacters(Data(farTable)) == nil)

        // A group count of 4 billion over the one group the data holds reads that group.
        var counted = Self.format12([(0x41, 0x41, 1)])
        counted.replaceSubrange(12..<16, with: Self.be32(0xFFFF_FFFF))
        #expect(FontCharacters(Self.font([(3, 10, counted)]))?.scalar(forGlyph: 1) == "A")

        // The first group spends the whole work cap on glyphs too high to keep, so the second, which
        // a font without the cap would read as "A" on glyph 7, is never reached. With a small first
        // group the second is read, so only the cap makes the difference.
        let spent = Self.font(
            [(3, 10, Self.format12([(0x20, 0x10FFFF, 0x1_0000), (0x41, 0x41, 7)]))])
        #expect(FontCharacters(spent) == nil)
        let unspent = Self.font(
            [(3, 10, Self.format12([(0x20, 0x20, 0x1_0000), (0x41, 0x41, 7)]))])
        #expect(FontCharacters(unspent)?.scalar(forGlyph: 7) == "A")

        // A format 4 with a segment count the data cannot hold.
        var many = Self.format4([(0x41, 0x41, 0, 0)])
        many.replaceSubrange(6..<8, with: Self.be16(0xFFFE))
        #expect(FontCharacters(Self.font([(3, 1, many)])) == nil)
    }

    // MARK: CIDs to characters

    @Test("a CID goes to a glyph through the CIDToGIDMap, and the glyph to its character")
    func cidToCharacter() throws {
        let characters = try #require(Self.characters(Self.letters))
        // CID 7 is glyph 1 ("A"), CID 8 glyph 3 ("C"), CID 9 glyph 0.
        let map = EmbeddedCharacters(
            characters: characters, glyphs: [0, 0, 0, 0, 0, 0, 0, 1, 3, 0])
        #expect(map.character(forCID: 7) == "A")
        #expect(map.character(forCID: 8) == "C")
        #expect(map.character(forCID: 9) == nil)
        #expect(map.character(forCID: 500) == nil)

        // With no map the CID is the glyph.
        let identity = EmbeddedCharacters(characters: characters, glyphs: nil)
        #expect(identity.character(forCID: 2) == "B")
        #expect(identity.character(forCID: 0x1_0002) == nil)
    }

    @Test("a CIDToGIDMap stream is two-byte entries, and a trailing byte is ignored")
    func glyphMap() {
        #expect(
            EmbeddedCharacters.glyphs(in: Data([0, 1, 1, 0, 0xFF, 0xFF, 7])) == [1, 256, 65_535])
        #expect(EmbeddedCharacters.glyphs(in: Data()).isEmpty)
    }

    @Test("where the font shows its CIDs are Unicode, a space it left out is a space")
    func spaceInUnicodeFont() throws {
        let characters = try #require(Self.characters(Self.letters))
        // CIDs 0x41 to 0x43 are glyphs 1 to 3, which the font says are the same characters.
        var glyphs = [UInt16](repeating: 0, count: 0x51)
        glyphs[0x41] = 1
        glyphs[0x42] = 2
        glyphs[0x43] = 3
        let unicode = EmbeddedCharacters(characters: characters, glyphs: glyphs)
        #expect(unicode.cidsAreUnicode)
        #expect(unicode.character(forCID: 0x20) == " ")
        #expect(unicode.character(forCID: 0xA0) == "\u{A0}")
        // Only spaces: a missing letter stays missing.
        #expect(unicode.character(forCID: 0x44) == nil)

        // CID 1 is "A", so the CIDs are not Unicode, and a missing CID 0x20 is not a space.
        var numbered = [UInt16](repeating: 0, count: 0x21)
        numbered[1] = 1
        let other = EmbeddedCharacters(characters: characters, glyphs: numbered)
        #expect(!other.cidsAreUnicode)
        #expect(other.character(forCID: 0x20) == nil)

        // One CID that agrees and one that does not: not Unicode.
        glyphs[0x50] = 2
        #expect(!EmbeddedCharacters(characters: characters, glyphs: glyphs).cidsAreUnicode)

        // A single agreeing CID could be a coincidence.
        var single = [UInt16](repeating: 0, count: 0x42)
        single[0x41] = 1
        let one = EmbeddedCharacters(characters: characters, glyphs: single)
        #expect(!one.cidsAreUnicode)
        #expect(one.character(forCID: 0x20) == nil)

        // No CIDToGIDMap: nothing to show it by.
        #expect(!EmbeddedCharacters(characters: characters, glyphs: nil).cidsAreUnicode)
    }

    // MARK: Through the reader

    /// A PDF showing `codes` (hex, two bytes each) in an `Identity-H` CID font that embeds `font`,
    /// with `glyphs` as its `CIDToGIDMap` stream, or `/Identity`, and an optional `ToUnicode` map.
    static func pdf(codes: String, font: Data, glyphs: [Int]?, toUnicode: String? = nil) -> MiniPDF
    {
        // Objects 1 to 3 are the font, its descendant and the descriptor; streams follow.
        var objects = ["", "", ""]
        func add(_ body: String) -> String {
            objects.append(body)
            return "{\(objects.count)}"
        }
        let fontFile = add(MiniPDF.stream("", String(decoding: font, as: UTF8.self)))
        var map = "/CIDToGIDMap /Identity"
        if let glyphs {
            let entries = glyphs.flatMap(Self.be16)
            map =
                "/CIDToGIDMap " + add(MiniPDF.stream("", String(decoding: entries, as: UTF8.self)))
        }
        var unicode = ""
        if let toUnicode { unicode = "/ToUnicode " + add(MiniPDF.stream("", toUnicode)) }
        objects[0] = """
            << /Type /Font /Subtype /Type0 /BaseFont /AAAAAA+Test /Encoding /Identity-H \
            /DescendantFonts [{2}] \(unicode) >>
            """
        objects[1] = """
            << /Type /Font /Subtype /CIDFontType2 /BaseFont /AAAAAA+Test \
            /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> \
            /FontDescriptor {3} \(map) /DW 600 >>
            """
        objects[2] =
            "<< /Type /FontDescriptor /FontName /AAAAAA+Test /Flags 32 /FontFile2 \(fontFile) >>"
        var pdf = MiniPDF(content: "BT /F1 10 Tf 100 100 Td <\(codes)> Tj ET")
        pdf.objects = objects
        pdf.resources = "<< /Font << /F1 {1} >> >>"
        return pdf
    }

    /// The first run of the page `pdf` makes.
    static func run(_ pdf: MiniPDF) throws -> PDF.TextRun {
        try #require(try InterpreterTests.page(pdf).texts.first)
    }

    /// CID `c` to glyph `g` for each `(c, g)`, and glyph 0 elsewhere up to CID `last`.
    static func glyphs(_ pairs: [Int: Int], last: Int) -> [Int] {
        (0...last).map { pairs[$0] ?? 0 }
    }

    @Test("an Identity font with no ToUnicode map is read through its embedded font")
    func readsThroughTheFont() throws {
        // CIDs are Unicode here: 0x41 to 0x43 are glyphs 1 to 3, and the space is in no glyph.
        let glyphs = Self.glyphs([0x41: 1, 0x42: 2, 0x43: 3], last: 0x43)
        let run = try Self.run(
            Self.pdf(codes: "0041004200200043", font: Self.font(Self.letters), glyphs: glyphs))
        #expect(run.ownText == "AB C")
        #expect(run.text == "AB C")
        #expect(run.decoding == .embeddedFont)
    }

    @Test(
        "a code the font has no character for is U+FFFD, and a space is not guessed unless CIDs are Unicode"
    )
    func unresolvedCodes() throws {
        let font = Self.font(Self.letters)
        let unicode = Self.glyphs([0x41: 1], last: 0x44)
        #expect(
            try Self.run(Self.pdf(codes: "00410044", font: font, glyphs: unicode)).ownText
                == "A\u{FFFD}")

        // CID 1 is "A": the CIDs are numbers, not Unicode, so CID 0x20 is not a space.
        let numbered = Self.glyphs([1: 1], last: 0x20)
        #expect(
            try Self.run(Self.pdf(codes: "00010020", font: font, glyphs: numbered)).ownText
                == "A\u{FFFD}")
    }

    @Test("with no CIDToGIDMap the codes are the glyph numbers")
    func identityMap() throws {
        let run = try Self.run(
            Self.pdf(codes: "000100020003", font: Self.font(Self.letters), glyphs: nil))
        #expect(run.ownText == "ABC")
        #expect(run.decoding == .embeddedFont)
    }

    @Test("an embedded font with no Unicode cmap gives no text of its own")
    func noUsableCMap() throws {
        let macintosh = Self.font([(1, 0, Self.format12([(0x41, 0x43, 1)]))])
        let run = try Self.run(
            Self.pdf(codes: "000100020003", font: macintosh, glyphs: nil))
        #expect(run.ownText == nil)
    }

    @Test("a complete ToUnicode map is used before the font")
    func toUnicodeFirst() throws {
        // The map says CID 0x41 is "Z"; the font says "A".
        let map = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 beginbfchar <0041> <005A> endbfchar
            endcmap end end
            """
        let glyphs = Self.glyphs([0x41: 1], last: 0x41)
        let run = try Self.run(
            Self.pdf(codes: "0041", font: Self.font(Self.letters), glyphs: glyphs, toUnicode: map))
        #expect(run.ownText == "Z")
        #expect(run.decoding == .toUnicode)
    }

    @Test("a ToUnicode map with gaps is kept unless the font leaves fewer codes unread")
    func toUnicodeWithGaps() throws {
        func map(_ entries: String) -> String {
            """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            \(entries)
            endcmap end end
            """
        }
        let font = Self.font(Self.letters)
        let codes = "0041004200430044"

        // The map reads three of the four codes as "XYZ"; the font reads only the first, so it
        // would leave three unread and the map's reading stands, with its one gap. (`ownText`: with
        // a U+FFFD in it, a run's `text` may be replaced by PDFKit's.)
        let narrow = try Self.run(
            Self.pdf(
                codes: codes, font: font, glyphs: Self.glyphs([0x41: 1], last: 0x44),
                toUnicode: map("1 beginbfrange <0041> <0043> <0058> endbfrange")))
        #expect(narrow.ownText == "XYZ\u{FFFD}")

        // The map reads only the first code, leaving three; the font reads three of the four, so
        // it leaves fewer unread and replaces the map's reading.
        let wide = try Self.run(
            Self.pdf(
                codes: codes, font: font,
                glyphs: Self.glyphs([0x41: 1, 0x42: 2, 0x43: 3], last: 0x44),
                toUnicode: map("1 beginbfchar <0041> <0058> endbfchar")))
        #expect(wide.ownText == "ABC\u{FFFD}")
    }
}
