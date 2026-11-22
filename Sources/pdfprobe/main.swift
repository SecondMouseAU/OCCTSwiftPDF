// main.swift
// pdfprobe
//
// Reports what PDF drawings are made of, and how a PDF compares with the DXF of the same drawing.
//
//   pdfprobe [--detail] <file-or-folder>...   one line per PDF (vector, raster or mixed)
//   pdfprobe compare <pdf> <dxf-or-zip>         the PDF's first page against the DXF
//   pdfprobe pairs <folder>                     every <name>.pdf beside <name>_dxf.zip, or beside
//                                               <name>_jww.zip or .lzh where that is missing
//   pdfprobe arcs [--detail] <file-or-folder>...  the circles and arcs recovered, by producer
//   pdfprobe arc-pairs [--detail] [--bound <mm>] [--table <file>] <folder>
//                                               the same against the circles and arcs of each
//                                               PDF's paired DXF or JWW, by coordinates
//   pdfprobe digest <file-or-folder>...         a hash of each page's `drawing()`, to see that a
//                                               change to the reader left it alone
//
// `arcs` and `arc-pairs` take the options of `PDF.ArcFitting` as `--tolerance`, `--relative`,
// `--line-tolerance`, `--min-sweep`, `--max-step`, `--min-lines` and `--max-ratio`.
// `PDFPROBE_PLACEMENTS=<file>` keeps the reference placements of `arc-pairs` between runs.
//
// `--exclude-layer <name>` (repeatable) leaves a DXF layer out of a comparison, such as Jw_cad's
// auxiliary lines (`ADD_LINE` in the TECS DXFs), which are never printed.
//
// macOS only: it reads PDFs through PDFKit as well and runs `/usr/bin/unzip`. Where there is no
// `Process` it builds, so the package's `-Package` scheme does, and says so.

import Foundation

#if os(macOS)
    import CoreGraphics
    import OCCTSwiftPDF
    import PDFKit
    import SwiftJWW

    enum PDFKitPage {
        static func first(_ url: URL) -> PDFPage? { PDFDocument(url: url)?.page(at: 0) }
    }

    /// The arguments without `--exclude-layer <name>` pairs, and the names.
    func parse(_ raw: [String]) -> (arguments: [String], excluded: Set<String>) {
        var arguments = raw
        var excluded: Set<String> = []
        while let flag = arguments.firstIndex(of: "--exclude-layer"), flag + 1 < arguments.count {
            excluded.insert(arguments[flag + 1])
            arguments.removeSubrange(flag...(flag + 1))
        }
        return (arguments, excluded)
    }

    let (arguments, excludedLayers) = parse(Array(CommandLine.arguments.dropFirst()))

    func pdfs(in paths: [String]) -> [URL] {
        var out: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
                continue
            }
            if isFolder.boolValue {
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil)
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
        let pageNote = pages.count < document.pageCount ? " (read \(pages.count))" : ""
        var line =
            "\(name)\t\(kind)\tpages \(document.pageCount)\(pageNote)\tsegments \(segments) (curves \(curves))"
        line += "\tfills \(fills)\ttext \(texts.count) (own \(own), PDFKit \(byKit), none \(none))"
        if invisible > 0 { line += "\tinvisible text \(invisible) (decoded \(invisibleDecoded))" }
        line += "\timages \(percent(coverage))\tlayers \(layers)\tforms \(forms)"
        print(line)
        guard detail else { return }
        print("  producer: \(document.producer ?? "-"); creator: \(document.creator ?? "-")")
        if !document.layers.isEmpty {
            print("  layers: \(document.layers.joined(separator: ", "))")
        }
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
        let filled = texts.filter { $0.decoding == .pdfKit }
        if !filled.isEmpty {
            let shown = filled.prefix(8).map {
                "\"\($0.text ?? "")\" at \(Int($0.rotationDeg.rounded())) degrees"
            }
            print("  PDFKit's characters used: \(shown.joined(separator: ", "))")
        }
        for (mine, kit) in differ.prefix(5) { print("    own \"\(mine)\" PDFKit \"\(kit)\"") }
        let shown = texts.isEmpty ? invisibleRuns : texts
        let samples = shown.compactMap(\.text).prefix(12).map { "\"\($0)\"" }.joined(separator: " ")
        print("  first texts: \(samples)")
    }

    /// A reference drawing: a DXF, a zip holding one, or a JWW (plain, or in a zip or LZH archive).
    ///
    /// A JWW is read by SwiftJWW at full size, as Jw_cad's own DXF export is, without Jw_cad's
    /// auxiliary lines and colours (number 9), which Jw_cad never prints.
    func referenceDrawing(at url: URL) throws -> DXF.Drawing {
        let name = url.lastPathComponent.lowercased()
        let isJWW =
            name.hasSuffix(".jww") || name.hasSuffix("_jww.zip") || name.hasSuffix(".lzh")
        guard isJWW else { return try PDF.readReference(at: url) }
        var jww = try JWW.read(data: try jwwData(at: url))
        jww.elements.removeAll { $0.attributes.lineType == 9 || $0.attributes.color == 9 }
        let output = DXFWriter.output(
            jww, options: DXFWriter.Options(fullSize: true, recoversDimensions: false))
        return try DXF.read(text: output.text, options: DXF.ReadOptions(expandBlocks: true))
    }

    /// The bytes of the one entry, a `.jww`, in a zip or LZH archive, read with `tar` (which reads
    /// both) to standard output, since the entry names are often Shift-JIS, which the file system
    /// refuses as names.
    func jwwData(at url: URL) throws -> Data {
        guard !url.lastPathComponent.lowercased().hasSuffix(".jww") else {
            return try Data(contentsOf: url)
        }
        let names = String(decoding: try run("/usr/bin/tar", ["-tf", url.path]), as: UTF8.self)
            .split(separator: "\n")
        guard names.count == 1, names[0].lowercased().hasSuffix(".jww") else {
            throw PDF.Error.cannotOpen
        }
        return try run("/usr/bin/tar", ["-xOf", url.path])
    }

    func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PDF.Error.cannotOpen }
        return data
    }

    /// The reference beside `<stem>.pdf`: `<stem>_dxf.zip` when it is a real zip, otherwise
    /// `<stem>_jww.zip` or `<stem>_jww.lzh`.
    func pairedReference(_ folder: URL, _ stem: String) -> URL? {
        let dxf = folder.appendingPathComponent("\(stem)_dxf.zip")
        if let head = try? FileHandle(forReadingFrom: dxf).read(upToCount: 2),
            head == Data("PK".utf8)
        {
            return dxf
        }
        for ext in ["zip", "lzh", "LZH"] {
            let jww = folder.appendingPathComponent("\(stem)_jww.\(ext)")
            if FileManager.default.fileExists(atPath: jww.path) { return jww }
        }
        return FileManager.default.fileExists(atPath: dxf.path) ? dxf : nil
    }

    func compareLine(_ pdf: String, _ reference: String) -> (
        line: String, result: PDF.Comparison?, pages: Int
    ) {
        let name = URL(fileURLWithPath: pdf).lastPathComponent
        guard let document = try? PDF.read(contentsOf: URL(fileURLWithPath: pdf), maximumPages: 1),
            let page = document.pages.first
        else { return ("\(name)\tcannot open the PDF", nil, 0) }
        guard var ref = try? referenceDrawing(at: URL(fileURLWithPath: reference)) else {
            return ("\(name)\tcannot read the DXF", nil, document.pageCount)
        }
        if !excludedLayers.isEmpty {
            ref.entities.removeAll { excludedLayers.contains(PDF.describe(layerOf: $0)) }
        }
        guard let result = PDF.compare(page.drawing(), with: ref) else {
            return (
                "\(name)\t\(page.kind.rawValue)\tfewer than two texts in common", nil,
                document.pageCount
            )
        }
        let d = result.referenceDistances.map { String(format: "%.3f", $0) }.joined(separator: "/")
        let pageCount = document.pageCount
        var line =
            "\(name)\t\(page.kind.rawValue)\tpages \(pageCount)\tanchors \(result.anchorsUsed)/\(result.anchors)"
        line += String(
            format: "\tscale %.5f\trotation %.2f\ttext residual %.3f mm\tgeometry residual %.3f mm",
            result.scale, result.rotationDeg, result.anchorResidual, result.geometryResidual)
        line +=
            "\tDXF covered \(percent(result.referenceCovered))\tPDF covered \(percent(result.pdfCovered))"
        line +=
            "\tdistances p50/p90/p99 \(d) mm\ttexts \(result.textsMatched)/\(result.referenceTexts)"
        if let worst = result.uncovered.max(by: { $0.value < $1.value }) {
            line +=
                "\tmost uncovered: layer \(worst.key) \(percent(Double(worst.value) / Double(max(result.referenceSamples, 1))))"
        }
        return (line, result, pageCount)
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

    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The figures the experiment page reports: single-page pairs are judged on their own, since a
    /// multi-page PDF is compared on its first page against a DXF holding every sheet.
    func printPairsSummary(_ results: [(result: PDF.Comparison, pages: Int)], failures: Int) {
        let single = results.filter { $0.pages == 1 }.map(\.result)
        print(
            "pairs compared: \(results.count) (single-page \(single.count)); not compared: \(failures)"
        )
        let dxf = single.map(\.referenceCovered)
        let pdf = single.map(\.pdfCovered)
        print(
            "single-page, DXF covered within 0.2 mm: median \(percent(median(dxf))), at least 95% "
                + "\(dxf.filter { $0 >= 0.95 }.count), at least 99% \(dxf.filter { $0 >= 0.99 }.count)"
        )
        print(
            "single-page, PDF covered within 0.2 mm: median \(percent(median(pdf))), at least 95% "
                + "\(pdf.filter { $0 >= 0.95 }.count)")
        let both = single.filter { $0.referenceCovered >= 0.95 && $0.pdfCovered >= 0.95 }
        print(
            "single-page with both sides at least 95%: \(both.count) of \(single.count); in those, "
                + String(
                    format: "median distance %.3f mm, median 90th percentile %.3f mm",
                    median(both.map { $0.referenceDistances[0] }),
                    median(both.map { $0.referenceDistances[1] })))
        let matched = single.reduce(0) { $0 + $1.textsMatched }
        let total = single.reduce(0) { $0 + $1.referenceTexts }
        print("single-page texts matched within 2 mm: \(matched) of \(total)")
        var scales: [String: Int] = [:]
        for (result, _) in results {
            let key =
                result.scale < 0.9
                ? "1:\(Int((1 / result.scale).rounded()))" : String(format: "%.4f", result.scale)
            scales[key, default: 0] += 1
        }
        let listed = scales.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        print("scales: \(listed.joined(separator: ", "))")
    }

    /// One line per PDF: the entity counts of every page's `drawing()` and a hash of all of them
    /// (entities and identities), so a change that should leave `drawing()` alone can be checked
    /// across the corpus by comparing two runs.
    func digest(_ url: URL) {
        let name = url.lastPathComponent
        guard let document = try? PDF.read(contentsOf: url) else {
            print("\(name)\tcannot open")
            return
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        var total = DXF.Drawing.Counts()
        for page in document.pages {
            let drawing = page.drawing()
            for (index, entity) in drawing.entities.enumerated() {
                mix(String(describing: entity))
                mix(drawing.identity(ofEntityAt: index).id)
            }
            mix(String(describing: drawing.skipped.sorted { $0.key < $1.key }))
            total.line += drawing.counts.line
            total.polyline += drawing.counts.polyline
            total.spline += drawing.counts.spline
            total.text += drawing.counts.text
            total.circle += drawing.counts.circle
            total.arc += drawing.counts.arc
        }
        print(
            "\(name)\tpages \(document.pages.count)\tlines \(total.line)\tpolylines \(total.polyline)"
                + "\tsplines \(total.spline)\tcircles \(total.circle)\tarcs \(total.arc)"
                + "\ttext \(total.text)\thash \(String(hash, radix: 16))")
    }

    /// The arc recovery options from `--tolerance`, `--relative`, `--min-sweep`, `--max-step` and
    /// `--min-lines`, and what is left of the arguments.
    func arcOptions(_ raw: [String]) -> (options: PDF.ArcFitting, rest: [String]) {
        var options = PDF.ArcFitting()
        var rest = raw
        func take(_ flag: String) -> Double? {
            guard let at = rest.firstIndex(of: flag), at + 1 < rest.count,
                let value = Double(rest[at + 1])
            else { return nil }
            rest.removeSubrange(at...(at + 1))
            return value
        }
        if let value = take("--tolerance") { options.tolerance = value }
        if let value = take("--relative") { options.relativeTolerance = value }
        if let value = take("--line-tolerance") { options.lineTolerance = value }
        if let value = take("--min-sweep") { options.minimumSweepDeg = value }
        if let value = take("--max-step") { options.maximumLineStepDeg = value }
        if let value = take("--min-lines") { options.minimumLineSegments = Int(value) }
        if let value = take("--max-ratio") { options.maximumStepRatio = value }
        return (options, rest)
    }

    switch arguments.first {
    case "arcs" where arguments.count >= 2:
        var (options, rest) = arcOptions(Array(arguments.dropFirst()))
        let detail = rest.contains("--detail")
        rest.removeAll { $0 == "--detail" }
        var results: [ArcFileResult] = []
        for url in pdfs(in: rest) {
            guard let result = arcResult(url, options) else {
                print("\(url.lastPathComponent)\tcannot open")
                continue
            }
            results.append(result)
            print(arcLine(result))
            if detail { result.fits.forEach(printArcFit) }
        }
        printArcSummary(results)
    case "arc-pairs" where arguments.count >= 2:
        var (options, rest) = arcOptions(Array(arguments.dropFirst()))
        let detail = rest.contains("--detail")
        rest.removeAll { $0 == "--detail" }
        var bound = 0.5
        if let at = rest.firstIndex(of: "--bound"), at + 1 < rest.count,
            let value = Double(rest[at + 1])
        {
            bound = value
            rest.removeSubrange(at...(at + 1))
        }
        var table: String?
        if let at = rest.firstIndex(of: "--table"), at + 1 < rest.count {
            table = rest[at + 1]
            rest.removeSubrange(at...(at + 1))
        }
        guard let folder = rest.first else { exit(2) }
        let results = arcPairs(
            URL(fileURLWithPath: folder), options, excluded: excludedLayers, detail: detail,
            bound: bound, table: table)
        printArcPairSummary(results)
    case "digest" where arguments.count >= 2:
        for url in pdfs(in: Array(arguments.dropFirst())) { digest(url) }
    case "debug-text" where arguments.count == 3:
        debugText(arguments[1], arguments[2])
    case "compare" where arguments.count == 3:
        let (line, result, _) = compareLine(arguments[1], arguments[2])
        print(line)
        if let result, !result.uncovered.isEmpty {
            let total = Double(result.referenceSamples)
            print(
                "  DXF geometry farther than \(result.tolerance) mm from the PDF, by layer and type:"
            )
            for (key, count) in result.uncovered.sorted(by: { $0.value > $1.value }).prefix(10) {
                print("    \(key): \(count) samples (\(percent(Double(count) / total)) of the DXF)")
            }
        }
        if let result, !result.pdfUncovered.isEmpty {
            let total = Double(result.pdfSamples)
            print(
                "  PDF geometry farther than \(result.tolerance) mm from the DXF, by layer and type:"
            )
            for (key, count) in result.pdfUncovered.sorted(by: { $0.value > $1.value }).prefix(10) {
                print("    \(key): \(count) samples (\(percent(Double(count) / total)) of the PDF)")
            }
        }
    case "pairs" where arguments.count == 2:
        let folder = URL(fileURLWithPath: arguments[1])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var results: [(result: PDF.Comparison, pages: Int)] = []
        var failures = 0
        var references: [String: Int] = [:]
        for file in files.sorted() where file.lowercased().hasSuffix(".pdf") {
            let stem = String(file.dropLast(4))
            guard let paired = pairedReference(folder, stem) else { continue }
            let compared = compareLine(folder.appendingPathComponent(file).path, paired.path)
            let via = paired.lastPathComponent.lowercased().contains("_jww.") ? "JWW" : "DXF"
            print(compared.line + "\treference \(via)")
            references[via, default: 0] += compared.result == nil ? 0 : 1
            if let result = compared.result {
                results.append((result, compared.pages))
            } else {
                failures += 1
            }
        }
        printPairsSummary(results, failures: failures)
        print("compared against: DXF \(references["DXF"] ?? 0), JWW \(references["JWW"] ?? 0)")
    default:
        let detail = arguments.contains("--detail")
        let paths = arguments.filter { $0 != "--detail" }
        guard !paths.isEmpty else {
            print(
                "usage: pdfprobe [--detail] <file-or-folder>... | compare <pdf> <dxf-or-zip> | "
                    + "pairs <folder> | digest <file-or-folder>... | "
                    + "arcs [--detail] <file-or-folder>... | arc-pairs [--detail] <folder> | "
                    + "debug-text <pdf> <text>; --exclude-layer <name> for compare, pairs and "
                    + "arc-pairs"
            )
            exit(2)
        }
        let files = pdfs(in: paths)
        for url in files { summary(url, detail: detail) }
        if files.count > 1 { print("\(files.count) PDFs") }
    }
#else
    print("pdfprobe runs on macOS only.")
    exit(1)
#endif
