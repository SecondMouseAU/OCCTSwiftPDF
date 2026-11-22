// FontCharacters.swift
// OCCTSwiftPDF
//
// The characters of an embedded TrueType font's glyphs, from the font's own `cmap` table.

import Foundation

/// The Unicode value of each glyph of a TrueType font, found by inverting its `cmap`.
///
/// A subset a writer embeds without a `ToUnicode` map still carries this table, and with a CID
/// font's `CIDToGIDMap` it says what character each code stands for. The font is untrusted input:
/// every read is bounds-checked and the work is capped.
///
/// CoreText was tried first. It loads the ODA subset and maps characters to glyphs, but only that
/// way round and only for a font it accepts whole: it refuses one that has just a `cmap`, which is
/// all a small hand-built test font can have. Reading the one table needed does not depend on the
/// system accepting the font, and the tests can run on a hand-built one.
struct FontCharacters {
    /// The most code points one font may walk; a real subset has a few thousand.
    private static let budget = 1 << 20

    /// The lowest code point mapped to each glyph, so a glyph that is both a space and a no-break
    /// space reads as the space.
    private var byGlyph: [UInt16: UInt32] = [:]

    /// The character for `glyph`, or `nil` when the font's Unicode `cmap` has none.
    func scalar(forGlyph glyph: UInt16) -> Unicode.Scalar? {
        byGlyph[glyph].flatMap { Unicode.Scalar($0) }
    }

    /// The characters of the glyphs in the font `data`, or `nil` when it has no Unicode `cmap` this
    /// can read (formats 4 and 12, under the Unicode platform or Windows encodings 1 and 10).
    init?(_ data: Data) {
        let font = Reader(bytes: [UInt8](data))
        // A TrueType font: `0x00010000` or `true`.
        guard let version = font.u32(0), [0x0001_0000, 0x7472_7565].contains(version),
            let tables = font.u16(4), tables <= 256
        else { return nil }
        var cmap: Int?
        for index in 0..<tables {
            let record = 12 + 16 * index
            if font.u32(record) == 0x636D_6170, let offset = font.u32(record + 8) {
                cmap = offset
                break
            }
        }
        guard let cmap, let subtables = font.u16(cmap + 2) else { return nil }
        var remaining = Self.budget
        for index in 0..<min(subtables, 64) {
            let record = cmap + 4 + 8 * index
            guard let platform = font.u16(record), let encoding = font.u16(record + 2),
                let offset = font.u32(record + 4),
                platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
            else { continue }
            switch font.u16(cmap + offset) {
            case 4: addSegments(font, at: cmap + offset, remaining: &remaining)
            case 12: addGroups(font, at: cmap + offset, remaining: &remaining)
            default: break
            }
        }
        guard !byGlyph.isEmpty else { return nil }
    }

    /// Format 4: segments of two-byte codes, mapped by a delta or through a glyph index array.
    private mutating func addSegments(_ font: Reader, at start: Int, remaining: inout Int) {
        guard let doubled = font.u16(start + 6) else { return }
        let ends = start + 14
        let firsts = ends + doubled + 2
        let deltas = firsts + doubled
        let offsets = deltas + doubled
        for segment in 0..<(doubled / 2) {
            guard let end = font.u16(ends + 2 * segment),
                let first = font.u16(firsts + 2 * segment),
                let delta = font.i16(deltas + 2 * segment),
                let rangeOffset = font.u16(offsets + 2 * segment)
            else { continue }
            let last = min(end, 0xFFFE)
            guard first <= last else { continue }
            for code in first...last {
                remaining -= 1
                if remaining < 0 { return }
                if rangeOffset == 0 {
                    add(code, glyph: (code + delta) & 0xFFFF)
                } else if let raw = font.u16(
                    offsets + 2 * segment + rangeOffset + 2 * (code - first)), raw != 0
                {
                    add(code, glyph: (raw + delta) & 0xFFFF)
                }
            }
        }
    }

    /// Format 12: groups of consecutive code points on consecutive glyphs.
    private mutating func addGroups(_ font: Reader, at start: Int, remaining: inout Int) {
        guard let count = font.u32(start + 12) else { return }
        for group in 0..<min(count, (font.bytes.count - start) / 12) {
            remaining -= 1
            if remaining < 0 { return }
            let record = start + 16 + 12 * group
            guard let first = font.u32(record), let last = font.u32(record + 4),
                let glyph = font.u32(record + 8), first <= last, last <= 0x10FFFF
            else { continue }
            for code in first...last {
                remaining -= 1
                if remaining < 0 { return }
                add(code, glyph: glyph + code - first)
            }
        }
    }

    private mutating func add(_ code: Int, glyph: Int) {
        // Glyph 0 is `.notdef`; control characters and surrogates are not text.
        guard glyph > 0, glyph <= 0xFFFF, code >= 0x20, !(0xD800...0xDFFF).contains(code),
            code <= 0x10FFFF
        else { return }
        let key = UInt16(glyph)
        if let existing = byGlyph[key], Int(existing) <= code { return }
        byGlyph[key] = UInt32(code)
    }

    /// Big-endian reads that return `nil` past the end of the font.
    fileprivate struct Reader {
        let bytes: [UInt8]

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }

        func i16(_ offset: Int) -> Int? {
            u16(offset).map { $0 >= 0x8000 ? $0 - 0x1_0000 : $0 }
        }

        func u32(_ offset: Int) -> Int? {
            guard let high = u16(offset), let low = u16(offset + 2) else { return nil }
            return high << 16 | low
        }
    }
}

/// What an embedded TrueType CID font says each of its CIDs is: the glyph the `CIDToGIDMap` gives
/// (the same number when the map is `Identity`), then that glyph's character in the font's `cmap`.
struct EmbeddedCharacters {
    let characters: FontCharacters
    /// Glyph for each CID from a `CIDToGIDMap` stream; `nil` for `Identity`.
    let glyphs: [UInt16]?
    /// The font itself shows its CIDs are Unicode values.
    ///
    /// It resolves at least two CIDs, and every one it resolves is the CID: one agreeing CID could
    /// be a coincidence in a font that numbers its CIDs in order. ODA's writer works this way.
    let cidsAreUnicode: Bool

    init(characters: FontCharacters, glyphs: [UInt16]?) {
        self.characters = characters
        self.glyphs = glyphs
        var agreed = 0
        var contradicted = false
        for (cid, glyph) in (glyphs ?? []).enumerated() where glyph != 0 {
            guard let scalar = characters.scalar(forGlyph: glyph) else { continue }
            if Int(scalar.value) == cid {
                agreed += 1
            } else {
                contradicted = true
                break
            }
        }
        cidsAreUnicode = agreed >= 2 && !contradicted
    }

    /// A `CIDToGIDMap` stream's two-byte, big-endian entries.
    static func glyphs(in map: Data) -> [UInt16] {
        let bytes = [UInt8](map)
        return stride(from: 0, to: bytes.count - 1, by: 2).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
    }

    /// The character for `cid`, or `nil` when the font gives none.
    ///
    /// A space has no outline, so a subset leaves it out of its `cmap`. Where the font has shown
    /// its CIDs are Unicode, a space CID the font cannot resolve is that space.
    func character(forCID cid: UInt32) -> Character? {
        let scalar: Unicode.Scalar?
        if let glyphs {
            scalar = Int(cid) < glyphs.count ? characters.scalar(forGlyph: glyphs[Int(cid)]) : nil
        } else {
            scalar = UInt16(exactly: cid).flatMap { characters.scalar(forGlyph: $0) }
        }
        if let scalar { return Character(scalar) }
        if cidsAreUnicode, let space = Unicode.Scalar(cid),
            space.properties.generalCategory == .spaceSeparator
        {
            return Character(space)
        }
        return nil
    }
}
