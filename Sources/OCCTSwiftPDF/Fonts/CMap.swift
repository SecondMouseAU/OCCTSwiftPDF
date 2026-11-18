// CMap.swift
// OCCTSwiftPDF
//
// A CMap stream: the code space (how many bytes each character code takes) and, for a ToUnicode
// map, the characters each code stands for.

import Foundation

/// The parts of a CMap stream this reader uses.
struct CMap {
    /// One `begincodespacerange` entry: codes of `length` bytes from `low` to `high`, compared byte
    /// by byte.
    struct CodeSpaceRange {
        var low: [UInt8]
        var high: [UInt8]
        var length: Int { low.count }

        func contains(_ bytes: ArraySlice<UInt8>) -> Bool {
            guard bytes.count == low.count else { return false }
            for (offset, byte) in bytes.enumerated()
            where byte < low[offset] || byte > high[offset] {
                return false
            }
            return true
        }
    }

    var codeSpace: [CodeSpaceRange] = []
    /// `bfchar` and expanded `bfrange` entries: code to characters.
    var characters: [UInt32: String] = [:]

    /// Ranges kept unexpanded because they are large: `low...high` maps to `start` plus the offset.
    var ranges: [(low: UInt32, high: UInt32, start: [UInt16])] = []

    func string(for code: UInt32) -> String? {
        if let found = characters[code] { return found }
        for range in ranges where code >= range.low && code <= range.high {
            var units = range.start
            if let last = units.popLast() {
                units.append(last &+ UInt16(truncatingIfNeeded: code - range.low))
            }
            return String(decoding: units, as: UTF16.self)
        }
        return nil
    }

    /// The code at the start of `bytes`, by the code space, and how many bytes it takes.
    ///
    /// Without a code space every code takes `fallbackLength` bytes.
    func code(at bytes: ArraySlice<UInt8>, fallbackLength: Int) -> (code: UInt32, length: Int) {
        for length in 1...4 where bytes.count >= length {
            let candidate = bytes.prefix(length)
            if codeSpace.contains(where: { $0.contains(candidate) }) {
                return (Self.number(candidate), length)
            }
        }
        let length = min(max(fallbackLength, 1), bytes.count)
        return (Self.number(bytes.prefix(length)), length)
    }

    static func number<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Parse a CMap's text.
    init(_ data: Data) {
        var tokens = Tokenizer(Array(data))
        var section = ""
        var pending: [Token] = []
        while let token = tokens.next() {
            if case .word(let word) = token {
                switch word {
                case "begincodespacerange", "beginbfchar", "beginbfrange":
                    section = word
                    pending = []
                    continue
                case "endcodespacerange", "endbfchar", "endbfrange":
                    section = ""
                    pending = []
                    continue
                default:
                    break
                }
            }
            guard !section.isEmpty else { continue }
            pending.append(token)
            switch section {
            case "begincodespacerange" where pending.count == 2:
                if case .hex(let low) = pending[0], case .hex(let high) = pending[1],
                    low.count == high.count, !low.isEmpty
                {
                    codeSpace.append(CodeSpaceRange(low: low, high: high))
                }
                pending = []
            case "beginbfchar" where pending.count == 2:
                if case .hex(let source) = pending[0], case .hex(let target) = pending[1] {
                    characters[Self.number(source)] = Self.utf16(target)
                }
                pending = []
            case "beginbfrange" where pending.count == 3:
                addRange(pending)
                pending = []
            default:
                break
            }
        }
    }

    private mutating func addRange(_ entry: [Token]) {
        guard case .hex(let lowBytes) = entry[0], case .hex(let highBytes) = entry[1] else {
            return
        }
        let low = Self.number(lowBytes)
        let high = Self.number(highBytes)
        guard high >= low, high - low < 65_536 else { return }
        switch entry[2] {
        case .hex(let start):
            ranges.append((low, high, Self.units(start)))
        case .array(let targets):
            for (offset, target) in targets.enumerated() where low + UInt32(offset) <= high {
                characters[low + UInt32(offset)] = Self.utf16(target)
            }
        default:
            break
        }
    }

    static func units(_ bytes: [UInt8]) -> [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
    }

    static func utf16(_ bytes: [UInt8]) -> String {
        String(decoding: units(bytes), as: UTF16.self)
    }

    enum Token {
        case hex([UInt8])
        case array([[UInt8]])
        case word(String)
    }

    /// Splits CMap text into hex strings, arrays of hex strings and words; everything else
    /// (names, numbers, dictionaries, comments) comes back as words or is skipped.
    struct Tokenizer {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() -> Token? {
            skipSpace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "<"):
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                    index += 2
                    return .word("<<")
                }
                return .hex(hexString())
            case UInt8(ascii: "["):
                index += 1
                var items: [[UInt8]] = []
                while true {
                    skipSpace()
                    guard index < bytes.count else { break }
                    if bytes[index] == UInt8(ascii: "]") {
                        index += 1
                        break
                    }
                    if bytes[index] == UInt8(ascii: "<") {
                        items.append(hexString())
                    } else {
                        index += 1
                    }
                }
                return .array(items)
            case UInt8(ascii: "%"):
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
                return next()
            default:
                let start = index
                while index < bytes.count, !Self.isDelimiter(bytes[index]) { index += 1 }
                if index == start { index += 1 }
                return .word(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }

        private mutating func hexString() -> [UInt8] {
            index += 1
            var digits: [UInt8] = []
            while index < bytes.count, bytes[index] != UInt8(ascii: ">") {
                if let value = Self.hexValue(bytes[index]) { digits.append(value) }
                index += 1
            }
            index += 1
            if digits.count % 2 == 1 { digits.append(0) }
            return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
        }

        private mutating func skipSpace() {
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
        }

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12 || byte == 0
        }

        static func isDelimiter(_ byte: UInt8) -> Bool {
            isSpace(byte) || "<>[]()/{}%".utf8.contains(byte)
        }

        static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }
    }
}
