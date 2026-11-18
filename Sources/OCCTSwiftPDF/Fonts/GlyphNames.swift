// GlyphNames.swift
// OCCTSwiftPDF
//
// Standard glyph names to characters, for a simple font whose Differences array names its glyphs.
// The subset a drawing's dimension text needs, plus the `uniXXXX` and `uXXXX` forms.

import Foundation

enum GlyphNames {
    static func character(_ name: String) -> Character? {
        if name.count == 1, let only = name.first, only.isASCII, only.isLetter { return only }
        if let found = table[name] { return found }
        let hex: Substring
        if name.hasPrefix("uni"), name.count == 7 {
            hex = name.dropFirst(3)
        } else if name.hasPrefix("u"), (5...7).contains(name.count) {
            hex = name.dropFirst(1)
        } else {
            return nil
        }
        return UInt32(hex, radix: 16).flatMap(UnicodeScalar.init).map(Character.init)
    }

    private static let table: [String: Character] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$",
        "percent": "%", "ampersand": "&", "quotesingle": "'", "quoteright": "\u{2019}",
        "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",",
        "hyphen": "-", "minus": "\u{2212}", "period": ".", "slash": "/", "zero": "0", "one": "1",
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "colon": ":", "semicolon": ";", "less": "<", "equal": "=",
        "greater": ">", "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\",
        "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`",
        "quoteleft": "\u{2018}", "braceleft": "{", "bar": "|", "braceright": "}",
        "asciitilde": "~", "degree": "\u{00B0}", "plusminus": "\u{00B1}",
        "multiply": "\u{00D7}", "divide": "\u{00F7}", "mu": "\u{00B5}",
        "Oslash": "\u{00D8}", "oslash": "\u{00F8}", "diameter": "\u{2300}",
        "endash": "\u{2013}", "emdash": "\u{2014}", "bullet": "\u{2022}",
        "onehalf": "\u{00BD}", "onequarter": "\u{00BC}", "threequarters": "\u{00BE}",
        "registered": "\u{00AE}", "copyright": "\u{00A9}", "section": "\u{00A7}",
    ]
}
