// Reference.swift
// OCCTSwiftPDF
//
// Spike tooling: the reference drawing a PDF is compared with, from a DXF or a zip holding one.

import Foundation
import SwiftDXF

extension PDF {
    /// The drawing in a DXF file, or in a zip holding exactly one entry, a DXF, with block
    /// references expanded.
    ///
    /// The TECS zips name their entry in Shift-JIS, which a name round trip through UTF-8 loses,
    /// so the entry is extracted whole with `/usr/bin/unzip -p`, not by name.
    public static func readReference(at url: URL) throws -> DXF.Drawing {
        let options = DXF.ReadOptions(expandBlocks: true)
        guard url.pathExtension.lowercased() == "zip" else {
            return try DXF.read(contentsOf: url, options: options)
        }
        let names = String(decoding: try unzip(["-Z1", url.path]), as: UTF8.self)
        let entries = names.split(separator: "\n")
        guard entries.count == 1, entries[0].lowercased().hasSuffix(".dxf") else {
            throw Error.cannotOpen
        }
        return try DXF.read(data: try unzip(["-p", url.path]), options: options)
    }

    private static func unzip(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Error.cannotOpen }
        return data
    }
}
