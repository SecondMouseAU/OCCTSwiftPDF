// Font.swift
// OCCTSwiftPDF
//
// A PDF font, as far as reading text needs it: how its bytes split into character codes, how wide
// each character is, and how to get from codes back to characters.

import CoreGraphics
import Foundation
import SwiftDXF

/// A font resource, read once and kept for the page.
final class Font {
    let name: String
    let subtype: String
    /// `Type0`: codes of one or more bytes through a CMap.
    let isComposite: Bool
    /// A simple font's base encoding, or a composite font's predefined CMap name.
    let encodingName: String?
    let toUnicode: CMap?
    /// A composite font's own code space, from an embedded encoding CMap.
    let encodingCMap: CMap?
    /// A simple font's `Differences`: code to glyph name.
    let differences: [UInt32: String]
    let firstChar: Int
    let widths: [Double]
    let missingWidth: Double
    /// The font descriptor's symbolic flag: its glyphs are outside the standard Latin set, so its
    /// built-in encoding cannot be assumed.
    let isSymbolic: Bool
    /// The font program is in the file, so its built-in encoding is its own.
    let isEmbedded: Bool
    let defaultWidth: Double
    let cidWidths: [UInt32: Double]
    /// Glyph space to text space: 0.001, or a Type 3 font's own matrix.
    let glyphScale: Double
    /// A composite font's embedded TrueType program and its `CIDToGIDMap` stream, read only if a
    /// run needs them, since a font program can be large.
    private let embeddedFile: CGPDFStreamRef?
    private let cidToGIDMap: CGPDFStreamRef?
    private lazy var embeddedCharacters: EmbeddedCharacters? = {
        guard let embeddedFile, let data = PDFObjects.data(embeddedFile),
            let characters = FontCharacters(data)
        else { return nil }
        let glyphs = cidToGIDMap.flatMap { PDFObjects.data($0) }.map(EmbeddedCharacters.glyphs)
        return EmbeddedCharacters(characters: characters, glyphs: glyphs)
    }()

    init(_ dict: CGPDFDictionaryRef) {
        name = PDFObjects.name(dict, "BaseFont") ?? PDFObjects.name(dict, "Name") ?? "?"
        subtype = PDFObjects.name(dict, "Subtype") ?? "?"
        isComposite = subtype == "Type0"

        var encodingName = PDFObjects.name(dict, "Encoding")
        var differences: [UInt32: String] = [:]
        var encodingCMap: CMap?
        if let encoding = PDFObjects.dictionary(dict, "Encoding") {
            encodingName = PDFObjects.name(encoding, "BaseEncoding")
            if let list = PDFObjects.array(encoding, "Differences") {
                differences = Self.differences(list)
            }
        } else if isComposite, let stream = PDFObjects.stream(dict, "Encoding"),
            let data = PDFObjects.data(stream)
        {
            encodingCMap = CMap(data)
            if let streamDict = CGPDFStreamGetDictionary(stream) {
                encodingName = PDFObjects.name(streamDict, "CMapName")
            }
        }
        self.encodingName = encodingName
        self.differences = differences
        self.encodingCMap = encodingCMap

        if let stream = PDFObjects.stream(dict, "ToUnicode"), let data = PDFObjects.data(stream) {
            toUnicode = CMap(data)
        } else {
            toUnicode = nil
        }

        firstChar = PDFObjects.integer(dict, "FirstChar") ?? 0
        widths = PDFObjects.array(dict, "Widths").map(PDFObjects.numbers) ?? []
        var missing = 0.0
        var flags = 0
        var embedded = false
        if let descriptor = PDFObjects.dictionary(dict, "FontDescriptor") {
            missing = PDFObjects.number(descriptor, "MissingWidth") ?? 0
            flags = PDFObjects.integer(descriptor, "Flags") ?? 0
            embedded = ["FontFile", "FontFile2", "FontFile3"].contains {
                PDFObjects.stream(descriptor, $0) != nil
            }
        }
        isEmbedded = embedded
        missingWidth = missing
        isSymbolic = flags & 4 != 0

        var defaultWidth = 1000.0
        var cidWidths: [UInt32: Double] = [:]
        var embeddedFile: CGPDFStreamRef?
        var cidToGIDMap: CGPDFStreamRef?
        if isComposite, let descendants = PDFObjects.array(dict, "DescendantFonts") {
            var descendant: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                defaultWidth = PDFObjects.number(descendant, "DW") ?? 1000
                if let list = PDFObjects.array(descendant, "W") { cidWidths = Self.cidWidths(list) }
                if let descriptor = PDFObjects.dictionary(descendant, "FontDescriptor") {
                    embeddedFile = PDFObjects.stream(descriptor, "FontFile2")
                }
                cidToGIDMap = PDFObjects.stream(descendant, "CIDToGIDMap")
            }
        }
        self.defaultWidth = defaultWidth
        self.cidWidths = cidWidths
        self.embeddedFile = embeddedFile
        self.cidToGIDMap = cidToGIDMap

        if subtype == "Type3", let matrix = PDFObjects.array(dict, "FontMatrix"),
            let first = PDFObjects.numbers(matrix).first
        {
            glyphScale = first
        } else {
            glyphScale = 0.001
        }
    }

    /// The font's encoding is a Shift-JIS one, such as `90ms-RKSJ-H`.
    var isShiftJIS: Bool { encodingName?.contains("RKSJ") == true }

    /// The font's encoding is a Unicode one, such as `UniJIS-UCS2-H`.
    var isUnicodeCMap: Bool {
        guard let encodingName else { return false }
        return encodingName.contains("UCS2") || encodingName.contains("UTF16")
    }

    /// The character codes in `bytes`, with the number of bytes each takes.
    func codes(_ bytes: [UInt8]) -> [(code: UInt32, length: Int)] {
        var out: [(UInt32, Int)] = []
        var index = 0
        while index < bytes.count {
            let rest = bytes[index...]
            let next: (code: UInt32, length: Int)
            if !isComposite {
                next = (UInt32(bytes[index]), 1)
            } else if isShiftJIS {
                let lead = bytes[index]
                let double = (0x81...0x9F).contains(lead) || (0xE0...0xFC).contains(lead)
                let length = double && index + 1 < bytes.count ? 2 : 1
                next = (CMap.number(rest.prefix(length)), length)
            } else if let cmap = encodingCMap ?? toUnicode, !cmap.codeSpace.isEmpty {
                next = cmap.code(at: rest, fallbackLength: 2)
            } else {
                let length = min(2, rest.count)
                next = (CMap.number(rest.prefix(length)), length)
            }
            out.append(next)
            index += next.length
        }
        return out
    }

    /// A character's advance in text space units for a font size of 1.
    func advance(of code: UInt32, length: Int) -> Double {
        if isComposite {
            if isShiftJIS && length == 1 { return 0.5 }
            // `W` is keyed by CID. Only an Identity encoding makes the code the CID; for the
            // predefined CMaps (Shift-JIS, Unicode) the code-to-CID tables are not carried, so the
            // default width stands in.
            let width = codesAreCIDs ? (cidWidths[code] ?? defaultWidth) : defaultWidth
            return width * glyphScale
        }
        let index = Int(code) - firstChar
        let width = widths.indices.contains(index) ? widths[index] : missingWidth
        // A simple font with no widths at all is one of the standard 14; half an em is a fair
        // average for placing a run's end.
        return (widths.isEmpty && width == 0 ? 500 : width) * glyphScale
    }

    /// A simple font whose built-in encoding cannot be known: a symbolic, TrueType, Type 3 or
    /// embedded font with no base encoding.
    ///
    /// One of the standard Type 1 fonts with no encoding uses StandardEncoding, which agrees with
    /// ASCII for printable codes. These others take every code their `Differences` array does not
    /// name from their own built-in encoding, which can be anything, so such a code is only
    /// guessed to be ASCII.
    var builtInEncodingUnknown: Bool {
        !isComposite && encodingName == nil
            && (isSymbolic || subtype == "TrueType" || subtype == "Type3" || isEmbedded)
    }

    /// The character codes are the CIDs: an `Identity-H` or `Identity-V` encoding.
    var codesAreCIDs: Bool { encodingName?.hasPrefix("Identity") == true }

    /// `bytes` as characters, and how they were found; `nil` text when the font gives no way back.
    ///
    /// With a `ToUnicode` map, a code it does not cover takes the simple font's own character for
    /// that code when that character is known, and U+FFFD otherwise (also where it would only be
    /// guessed), so a value is never shortened silently
    /// (an unmapped `⌀` before `25.4` must not leave `25.4`). A composite font with gaps in its map
    /// is decoded through its CMap instead when that covers every code.
    ///
    /// Only a font with no map (or, if composite, an empty one) is read through its embedded font
    /// program, last: a map is the writer's own statement, and a font's `cmap` is not trusted to
    /// overrule or fill it.
    func decode(_ bytes: [UInt8]) -> (text: String?, decoding: PDF.TextDecoding) {
        let codes = codes(bytes)
        // A composite font's empty map says nothing, so it is as if it had none.
        guard let toUnicode, !(isComposite && toUnicode.isEmpty) else {
            return decodeWithoutToUnicode(bytes, codes)
                ?? embeddedText(codes).map { ($0, .embeddedFont) } ?? (nil, .none)
        }
        var text = ""
        var missing = 0
        for (code, _) in codes {
            if let found = toUnicode.string(for: code) {
                text += found
            } else if !isComposite, let (character, guessed) = simpleCharacter(code), !guessed {
                text.append(character)
            } else {
                text += "\u{FFFD}"
                missing += 1
            }
        }
        if missing > 0, isComposite, let other = decodeWithoutToUnicode(bytes, codes) {
            return other
        }
        return (text, .toUnicode)
    }

    private func decodeWithoutToUnicode(_ bytes: [UInt8], _ codes: [(code: UInt32, length: Int)])
        -> (text: String?, decoding: PDF.TextDecoding)?
    {
        if isComposite {
            if isShiftJIS { return (DXF.decodeCP932(bytes), .shiftJIS) }
            if isUnicodeCMap { return (CMap.utf16(bytes), .unicodeCMap) }
            return nil
        }
        var text = ""
        var anyGuessed = false
        for (code, _) in codes {
            guard let (character, guessed) = simpleCharacter(code) else { return nil }
            text.append(character)
            anyGuessed = anyGuessed || guessed
        }
        return (text, anyGuessed ? .asciiGuess : .simpleEncoding)
    }

    /// An `Identity` composite font's codes as characters, through its embedded TrueType program.
    ///
    /// Each code is a CID, the `CIDToGIDMap` gives its glyph, and the program's own `cmap` gives
    /// that glyph's character. A code with no character is U+FFFD; the result is `nil` when none
    /// has one.
    private func embeddedText(_ codes: [(code: UInt32, length: Int)]) -> String? {
        guard codesAreCIDs, let embeddedCharacters else { return nil }
        var text = ""
        var found = 0
        for (code, _) in codes {
            if let character = embeddedCharacters.character(forCID: code) {
                text.append(character)
                found += 1
            } else {
                text += "\u{FFFD}"
            }
        }
        return found > 0 ? text : nil
    }

    /// A simple font's character for `code`, and whether it is only guessed: a code its
    /// `Differences` array does not name, in a font whose built-in encoding is unknown.
    private func simpleCharacter(_ code: UInt32) -> (Character, guessed: Bool)? {
        if let glyph = differences[code] {
            return GlyphNames.character(glyph).map { ($0, false) }
        }
        let byte = UInt8(truncatingIfNeeded: code)
        let character: Character?
        switch encodingName {
        case "WinAnsiEncoding":
            character = String(data: Data([byte]), encoding: .windowsCP1252).flatMap(\.first)
        case "MacRomanEncoding":
            character = String(data: Data([byte]), encoding: .macOSRoman).flatMap(\.first)
        default:
            // StandardEncoding, or none: printable ASCII only.
            character = (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : nil
        }
        return character.map { ($0, builtInEncodingUnknown) }
    }

    private static func differences(_ list: CGPDFArrayRef) -> [UInt32: String] {
        var out: [UInt32: String] = [:]
        var code: UInt32 = 0
        for index in 0..<CGPDFArrayGetCount(list) {
            var number: CGPDFInteger = 0
            var name: UnsafePointer<CChar>?
            if CGPDFArrayGetInteger(list, index, &number) {
                code = UInt32(max(0, number))
            } else if CGPDFArrayGetName(list, index, &name), let name {
                out[code] = String(cString: name)
                code += 1
            }
        }
        return out
    }

    /// A CID font's `W` array: `c [w1 w2 ...]` and `cFirst cLast w` entries.
    private static func cidWidths(_ list: CGPDFArrayRef) -> [UInt32: Double] {
        var out: [UInt32: Double] = [:]
        var index = 0
        let count = CGPDFArrayGetCount(list)
        while index < count {
            var first: CGPDFReal = 0
            guard CGPDFArrayGetNumber(list, index, &first) else {
                index += 1
                continue
            }
            var run: CGPDFArrayRef?
            var last: CGPDFReal = 0
            var width: CGPDFReal = 0
            if index + 1 < count, CGPDFArrayGetArray(list, index + 1, &run), let run {
                for (offset, value) in PDFObjects.numbers(run).enumerated() {
                    out[UInt32(first) + UInt32(offset)] = value
                }
                index += 2
            } else if index + 2 < count, CGPDFArrayGetNumber(list, index + 1, &last),
                CGPDFArrayGetNumber(list, index + 2, &width), last >= first, last - first < 65_536
            {
                for cid in UInt32(first)...UInt32(last) { out[cid] = Double(width) }
                index += 3
            } else {
                index += 1
            }
        }
        return out
    }
}
