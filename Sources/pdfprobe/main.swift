// main.swift
// pdfprobe
//
// Reports what PDF drawings are made of, and how a PDF compares with the DXF of the same drawing.
//
//   pdfprobe [--detail] <file-or-folder>...   one line per PDF (vector, raster or mixed)
//   pdfprobe compare <pdf> <dxf-or-zip>         the PDF's first page against the DXF
//   pdfprobe pairs <folder>                     every <name>.pdf beside <name>_dxf.zip

import Foundation
import OCCTSwiftPDF
import PDFKit

enum PDFKitPage {
    static func first(_ url: URL) -> PDFPage? { PDFDocument(url: url)?.page(at: 0) }
}

let arguments = Array(CommandLine.arguments.dropFirst())

func pdfs(in paths: [String]) -> [URL] {
    var out: [URL] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { continue }
        if isFolder.boolValue {
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let next = walker?.nextObject() as? URL {
                if next.pathExtension.lowercased() == "pdf" { out.append(next) }
            }
        } else {
            out.append(url)
        }
    }
    return out.sorted { $0.path < $1.path }
}

func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

func summary(_ url: URL, detail: Bool) {
    let name = url.lastPathComponent
    guard let document = try? PDF.read(contentsOf: url, maximumPages: detail ? nil : 5) else {
        print("\(name)\tcannot open")
        return
    }
    let kinds = Dictionary(grouping: document.pages, by: \.kind).mapValues(\.count)
    let kind =
        kinds.count == 1
        ? kinds.keys.first!.rawValue
        : kinds.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", ")
    let pages = document.pages
    let segments = pages.reduce(0) { $0 + $1.segmentCount }
    let curves = pages.reduce(0) { sum, page in
        sum
            + page.paths.reduce(0) { s, path in
                s
                    + path.subpaths.reduce(0) {
                        $0
                            + $1.segments.filter { if case .curve = $0 { true } else { false } }
                            .count
                    }
            }
    }
    let texts = pages.flatMap(\.texts).filter { !$0.isInvisible }
    let invisibleRuns = pages.flatMap(\.texts).filter(\.isInvisible)
    let invisible = invisibleRuns.count
    let invisibleDecoded = invisibleRuns.filter { $0.text != nil }.count
    let own = texts.filter { $0.ownText != nil }.count
    let byKit = texts.filter { $0.decoding == .pdfKit }.count
    let none = texts.filter { $0.text == nil }.count
    let fills = pages.reduce(0) { $0 + $1.paths.filter { $0.paint == .fill }.count }
    let coverage = pages.map(\.imageCoverage).max() ?? 0
    let layers =
        document.layers.isEmpty ? Set(pages.flatMap(\.layers)).count : document.layers.count
    let forms = pages.reduce(0) { $0 + $1.formInvocations }
    var line = "\(name)\t\(kind)\tpages \(pages.count)\tsegments \(segments) (curves \(curves))"
    line += "\tfills \(fills)\ttext \(texts.count) (own \(own), PDFKit \(byKit), none \(none))"
    if invisible > 0 { line += "\tinvisible text \(invisible) (decoded \(invisibleDecoded))" }
    line += "\timages \(percent(coverage))\tlayers \(layers)\tforms \(forms)"
    print(line)
    guard detail else { return }
    print("  producer: \(document.producer ?? "-"); creator: \(document.creator ?? "-")")
    if !document.layers.isEmpty { print("  layers: \(document.layers.joined(separator: ", "))") }
    let fonts = Dictionary(grouping: texts, by: { "\($0.fontName) (\($0.fontSubtype))" })
    for (font, runs) in fonts.sorted(by: { $0.key < $1.key }) {
        let methods = Dictionary(grouping: runs, by: \.decoding).mapValues(\.count)
            .map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", ")
        print("  font \(font): \(runs.count) runs; \(methods)")
    }
    var agree = 0
    var differ: [(String, String)] = []
    for run in texts {
        guard let mine = run.ownText, let kit = run.pdfKitText else { continue }
        let a = mine.filter { !$0.isWhitespace }
        let b = kit.filter { !$0.isWhitespace }
        if a == b { agree += 1 } else { differ.append((a, b)) }
    }
    print("  own decoding against PDFKit: \(agree) agree, \(differ.count) differ")
    for (mine, kit) in differ.prefix(5) { print("    own \"\(mine)\" PDFKit \"\(kit)\"") }
    let shown = texts.isEmpty ? invisibleRuns : texts
    let samples = shown.compactMap(\.text).prefix(12).map { "\"\($0)\"" }.joined(separator: " ")
    print("  first texts: \(samples)")
}

func readReference(_ path: String) throws -> DXF.Drawing {
    let url = URL(fileURLWithPath: path)
    let options = DXF.ReadOptions(expandBlocks: true)
    guard url.pathExtension.lowercased() == "zip" else {
        return try DXF.read(contentsOf: url, options: options)
    }
    let list = Process()
    list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    list.arguments = ["-Z1", path]
    let listing = Pipe()
    list.standardOutput = listing
    try list.run()
    let names = String(decoding: listing.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    list.waitUntilExit()
    // The entry names are often Shift-JIS, which a name round trip through UTF-8 loses, so a zip
    // holding exactly one DXF is extracted whole rather than by name.
    let entries = names.split(separator: "\n").filter { $0.lowercased().hasSuffix(".dxf") }
    guard entries.count == 1 else { throw PDF.Error.cannotOpen }
    let extract = Process()
    extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    extract.arguments = ["-p", path]
    let output = Pipe()
    extract.standardOutput = output
    try extract.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    extract.waitUntilExit()
    return try DXF.read(data: data, options: options)
}

func compareLine(_ pdf: String, _ reference: String) -> (String, PDF.Comparison?) {
    let name = URL(fileURLWithPath: pdf).lastPathComponent
    guard let document = try? PDF.read(contentsOf: URL(fileURLWithPath: pdf), maximumPages: 1),
        let page = document.pages.first
    else { return ("\(name)\tcannot open the PDF", nil) }
    guard let ref = try? readReference(reference) else {
        return ("\(name)\tcannot read the DXF", nil)
    }
    guard let result = PDF.compare(page.drawing(), with: ref) else {
        return ("\(name)\t\(page.kind.rawValue)\tfewer than two texts in common", nil)
    }
    let d = result.referenceDistances.map { String(format: "%.3f", $0) }.joined(separator: "/")
    var line = "\(name)\t\(page.kind.rawValue)\tanchors \(result.anchorsUsed)/\(result.anchors)"
    line += String(
        format: "\tscale %.5f\trotation %.2f\ttext residual %.3f mm\tgeometry residual %.3f mm",
        result.scale, result.rotationDeg, result.anchorResidual, result.geometryResidual)
    line +=
        "\tDXF covered \(percent(result.referenceCovered))\tPDF covered \(percent(result.pdfCovered))"
    line += "\tdistances p50/p90/p99 \(d) mm\ttexts \(result.textsMatched)/\(result.referenceTexts)"
    if let worst = result.uncovered.max(by: { $0.value < $1.value }) {
        line +=
            "\tmost uncovered: layer \(worst.key) \(percent(Double(worst.value) / Double(max(result.referenceSamples, 1))))"
    }
    return (line, result)
}

/// Spike debugging: where the interpreter and PDFKit each put the first run containing `needle`.
func debugText(_ path: String, _ needle: String) {
    let url = URL(fileURLWithPath: path)
    guard let document = try? PDF.read(contentsOf: url, maximumPages: 1),
        let page = document.pages.first,
        let kit = PDFKitPage.first(url)
    else { return }
    print("mediaBox \(page.mediaBox) cropBox \(page.cropBox) rotation \(page.rotation)")
    print(
        "PDFKit bounds(mediaBox) \(kit.bounds(for: .mediaBox)) cropBox \(kit.bounds(for: .cropBox)) rotation \(kit.rotation)"
    )
    if let run = page.texts.first(where: { ($0.text ?? "").contains(needle) }) {
        print(
            "run \"\(run.text ?? "")\" origin \(run.origin) width \(run.width) height \(run.height) rotation \(run.rotationDeg)"
        )
    }
    if let string = kit.string, let range = string.range(of: needle) {
        let index = string.utf16.distance(
            from: string.utf16.startIndex, to: range.lowerBound.samePosition(in: string.utf16)!)
        let selection = kit.selection(for: NSRange(location: index, length: needle.utf16.count))
        print(
            "PDFKit selection bounds \(selection?.bounds(for: kit) ?? .zero) string \"\(selection?.string ?? "")\""
        )
    }
}

switch arguments.first {
case "debug-text" where arguments.count == 3:
    debugText(arguments[1], arguments[2])
case "compare" where arguments.count == 3:
    let (line, result) = compareLine(arguments[1], arguments[2])
    print(line)
    if let result, !result.uncovered.isEmpty {
        let total = Double(result.referenceSamples)
        print("  DXF geometry farther than \(result.tolerance) mm from the PDF, by layer and type:")
        for (key, count) in result.uncovered.sorted(by: { $0.value > $1.value }).prefix(10) {
            print("    \(key): \(count) samples (\(percent(Double(count) / total)) of the DXF)")
        }
    }
case "pairs" where arguments.count == 2:
    let folder = URL(fileURLWithPath: arguments[1])
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    var results: [PDF.Comparison] = []
    var failures = 0
    for file in files.sorted() where file.lowercased().hasSuffix(".pdf") {
        let stem = String(file.dropLast(4))
        let zip = folder.appendingPathComponent("\(stem)_dxf.zip").path
        guard FileManager.default.fileExists(atPath: zip) else { continue }
        let (line, result) = compareLine(folder.appendingPathComponent(file).path, zip)
        print(line)
        if let result { results.append(result) } else { failures += 1 }
    }
    let covered = results.map(\.referenceCovered).sorted()
    func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values[values.count / 2] }
    print("pairs compared: \(results.count); not compared: \(failures)")
    print(
        "DXF covered within 0.2 mm, median: \(percent(median(covered))); at least 95%: \(covered.filter { $0 >= 0.95 }.count); at least 99%: \(covered.filter { $0 >= 0.99 }.count)"
    )
    print(
        "PDF covered within 0.2 mm, median: \(percent(median(results.map(\.pdfCovered).sorted())))")
default:
    let detail = arguments.contains("--detail")
    let paths = arguments.filter { $0 != "--detail" }
    guard !paths.isEmpty else {
        print(
            "usage: pdfprobe [--detail] <file-or-folder>... | compare <pdf> <dxf-or-zip> | pairs <folder>"
        )
        exit(2)
    }
    let files = pdfs(in: paths)
    for url in files { summary(url, detail: detail) }
    if files.count > 1 { print("\(files.count) PDFs") }
}
