import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Real drawings from the corpus, which is not in the repository.
///
/// The corpus is `PDF_CORPUS`, or `~/Projects/OCCTDesignLoop/drawingfiles` when that is unset.
/// Each test is skipped where its files are absent, as in CI, and fails like any test where they
/// are present.
@Suite("Corpus")
struct CorpusTests {
    static let corpus: URL = {
        if let path = ProcessInfo.processInfo.environment["PDF_CORPUS"] {
            return URL(fileURLWithPath: path)
        }
        return URL(
            fileURLWithPath: NSString(string: "~/Projects/OCCTDesignLoop/drawingfiles")
                .expandingTildeInPath)
    }()

    static func file(_ path: String) -> URL { corpus.appendingPathComponent(path) }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: file(path).path)
    }

    /// The DXF of the 2120 made from its JWW, kept beside the JWW outside the corpus.
    static let the2120DXF = URL(
        fileURLWithPath: NSString(string: "~/Documents/Modelling/2DFiles/2120_from_2120j.dxf")
            .expandingTildeInPath)

    /// The single DXF in a TECS zip, extracted whole (its entry name is Shift-JIS).
    static func dxf(inZip url: URL) throws -> DXF.Drawing {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z1", url.path]
        let listing = Pipe()
        list.standardOutput = listing
        try list.run()
        let names = String(
            decoding: listing.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        try #require(names.split(separator: "\n").count == 1, "the zip must hold one entry")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path]
        let output = Pipe()
        unzip.standardOutput = output
        try unzip.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        return try DXF.read(data: data, options: DXF.ReadOptions(expandBlocks: true))
    }

    @Test(
        "the McMaster sheets are vector, and all their text is decoded by this reader",
        .enabled(if: CorpusTests.exists("PDFs/McMaster")))
    func mcMaster() throws {
        let folder = Self.file("PDFs/McMaster")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.lowercased().hasSuffix(".pdf") }
        #expect(!files.isEmpty)
        for name in files {
            let document = try PDF.read(contentsOf: folder.appendingPathComponent(name))
            for page in document.pages {
                #expect(page.kind == .vector, "\(name)")
                for run in page.texts {
                    let own = try #require(run.ownText, "\(name)").filter { !$0.isWhitespace }
                    // PDFKit reads the same characters wherever it pairs a run.
                    if let kit = run.pdfKitText { #expect(own == kit, "\(name)") }
                }
            }
        }
    }

    @Test(
        "a TECS sheet matches the DXF of the same drawing",
        .enabled(if: CorpusTests.exists("tecs-pairs/ec01.pdf")))
    func tecsPair() throws {
        let page = try #require(
            try PDF.read(contentsOf: Self.file("tecs-pairs/ec01.pdf"), maximumPages: 1).pages.first)
        let reference = try Self.dxf(inZip: Self.file("tecs-pairs/ec01_dxf.zip"))
        let result = try #require(PDF.compare(page.drawing(), with: reference))
        #expect(result.referenceCovered >= 0.99)
        #expect(result.pdfCovered >= 0.99)
        #expect(result.textsMatched == result.referenceTexts)
        // Drawn at 1:100, so a full-size millimetre is a hundredth of a millimetre on the paper.
        #expect(abs(result.scale - 0.01) < 1e-4)
    }

    @Test(
        "the 2120 matches the drawing made from its JWW, and its dimension values are whole",
        .enabled(
            if: CorpusTests.exists("PDFs/2120.pdf")
                && FileManager.default.fileExists(atPath: CorpusTests.the2120DXF.path)))
    func the2120() throws {
        let page = try #require(try PDF.read(contentsOf: Self.file("PDFs/2120.pdf")).pages.first)
        let reference = try DXF.read(contentsOf: Self.the2120DXF)
        let result = try #require(PDF.compare(page.drawing(), with: reference))
        // The drawing has a box of seven lines on JWW layer 15 that was not printed (336 mm of
        // line, about 2 percent). Everything else is in the PDF.
        let missing = result.uncovered.filter { !$0.key.hasPrefix("15 ") }.values.reduce(0, +)
        #expect(Double(missing) / Double(result.referenceSamples) < 0.005)
        #expect(result.uncovered["15 LINE"] != nil)
        #expect(result.pdfCovered >= 0.99)
        #expect(abs(result.scale - 1) < 1e-3)
        let values = Set(page.texts.compactMap(\.text))
        for value in ["10,439", "2,057", "1,829", "9,525", "3,810", "133"] {
            #expect(values.contains(value), "\(value)")
        }
        #expect(page.texts.allSatisfy { $0.decoding == .shiftJIS })
    }

    @Test(
        "an AutoCAD sheet's layers and Form XObject are read",
        .enabled(if: CorpusTests.exists("PDFs/Pandrol_Rail_Clips_GTS-1322_1_REV01.pdf")))
    func autoCADLayers() throws {
        let document = try PDF.read(
            contentsOf: Self.file("PDFs/Pandrol_Rail_Clips_GTS-1322_1_REV01.pdf"))
        #expect(document.layers.contains("TEXT-0.25"))
        #expect(document.layers.contains("LINE-0.20"))
        let page = try #require(document.pages.first)
        #expect(page.formInvocations >= 1)
        #expect(page.paths.contains { $0.layer == "LINE-0.20" })
    }

    @Test(
        "text in a font with no way back to characters is kept, undecoded, and counted",
        .enabled(if: CorpusTests.exists("PDFs/Wing Triple.pdf")))
    func undecodableText() throws {
        let page = try #require(
            try PDF.read(contentsOf: Self.file("PDFs/Wing Triple.pdf")).pages.first)
        #expect(!page.texts.isEmpty)
        #expect(page.texts.allSatisfy { $0.text == nil && $0.decoding == .none })
        #expect(page.drawing().skipped["TEXT"] == page.texts.count)
    }

    @Test(
        "a PDF encrypted with an empty password is opened",
        .enabled(if: CorpusTests.exists("railway/nippon-steel-rail-profiles.pdf")))
    func emptyPassword() throws {
        let document = try PDF.read(
            contentsOf: Self.file("railway/nippon-steel-rail-profiles.pdf"), maximumPages: 1)
        #expect(document.pageCount >= 1)
    }
}
