// ShapeTextProbe.swift
// pdfprobe
//
// `pdfprobe ocr`: text drawn as shapes, recovered by OCR, and what was decided about every line of
// shapes. macOS only, as the rest of the tool is.

#if os(macOS)
    import CoreGraphics
    import Foundation
    import OCCTSwiftPDF

    enum ShapeTextProbe {
        // `ocr [--compare] [--detail] [--pages N] <file-or-folder>...`
        static func run(_ arguments: [String], files: ([String]) -> [URL]) {
            var compare = false
            var detail = false
            var pages = 1
            var paths: [String] = []
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--compare": compare = true
                case "--detail": detail = true
                case "--pages" where index + 1 < arguments.count:
                    pages = Int(arguments[index + 1]) ?? 1
                    index += 1
                default: paths.append(arguments[index])
                }
                index += 1
            }
            guard !paths.isEmpty else {
                print("usage: pdfprobe ocr [--compare] [--detail] [--pages N] <file-or-folder>...")
                exit(2)
            }
            var options = PDF.ShapeTextOptions()
            if compare { options.existingText = .compare }
            for url in files(paths) { report(url, options: options, pages: pages, detail: detail) }
        }

        static func report(
            _ url: URL, options: PDF.ShapeTextOptions, pages: Int, detail: Bool
        ) {
            let name = url.lastPathComponent
            guard let document = try? PDF.read(contentsOf: url, maximumPages: pages) else {
                print("\(name)\tcannot open")
                return
            }
            let start = Date()
            let recovery: PDF.ShapeTextRecovery
            do {
                recovery = try document.recoveringShapeText(options: options)
            } catch {
                print("\(name)\tfailed: \(error)")
                return
            }
            let seconds = Date().timeIntervalSince(start)
            for page in document.pages {
                guard let report = recovery.reports[page.number] else { continue }
                var line = "\(name)\tpage \(page.number)\tshapes \(report.shapes)"
                line += "\tregions \(report.regions)\taccepted \(report.accepted)"
                line += "\trejected \(report.rejectedCount)"
                let why = report.rejected.sorted { $0.value > $1.value }
                    .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
                if !why.isEmpty { line += " (\(why))" }
                line += "\ttoo small \(report.tooSmall)"
                if report.shapesInDenseBlobs > 0 {
                    line += "\tdense-blob shapes \(report.shapesInDenseBlobs)"
                }
                line += String(format: "\t%.1f s", seconds)
                print(line)
                guard
                    let recovered = recovery.document.pages.first(where: {
                        $0.number == page.number
                    })
                else { continue }
                if options.existingText == .compare { compareWithRead(report, page: recovered) }
                if detail { list(report) }
            }
        }

        static func normalised(_ text: String) -> String { text.filter { !$0.isWhitespace } }

        /// How accepted OCR compares with the text the page already has there.
        enum Agreement { case same, partOfRead, readIsPart, different }

        static func agreement(_ ocr: String, _ read: String) -> Agreement {
            let a = normalised(ocr)
            let b = normalised(read)
            if a == b { return .same }
            if b.contains(a) { return .partOfRead }
            if a.contains(b) { return .readIsPart }
            return .different
        }

        /// Accepted OCR against the text the page already has there, by string and by position.
        ///
        /// A region is one line of shapes, which can be a word of a longer line of text (a wide gap
        /// cuts it), so the OCR string is "part of" the page's text when it is found inside it.
        static func compareWithRead(_ report: PDF.ShapeTextReport, page: PDF.Page) {
            let compared = report.decisions.filter { $0.readText != nil && $0.recognised != nil }
            let accepted = compared.filter { $0.outcome == .accepted }
            var counts: [String: Int] = [:]
            for decision in accepted {
                let kind = agreement(decision.recognised ?? "", decision.readText ?? "")
                counts["\(kind)", default: 0] += 1
            }
            let withText = report.decisions.filter { $0.readText != nil }.count
            print(
                "  regions over text the page has: \(withText); accepted: \(accepted.count): "
                    + "same characters \(counts["same"] ?? 0), a part of the page's text "
                    + "\(counts["partOfRead"] ?? 0), the page's text is a part of it "
                    + "\(counts["readIsPart"] ?? 0), different \(counts["different"] ?? 0)")
            let rejected = compared.filter { $0.outcome != .accepted }
            let rejectedRight = rejected.filter {
                let kind = agreement($0.recognised ?? "", $0.readText ?? "")
                return kind == .same || kind == .partOfRead
            }
            print(
                "  recognised but rejected: \(rejected.count), of which what was read was the "
                    + "page's text (or a part of it) anyway: \(rejectedRight.count)")
            let runs = page.texts.filter {
                !$0.quad.isEmpty && $0.text != nil && $0.decoding != .ocr
            }
            var offsets: [Double] = []
            for decision in accepted {
                let corners = decision.quad
                let cx = corners.map(\.x).reduce(0, +) / Double(corners.count)
                let cy = corners.map(\.y).reduce(0, +) / Double(corners.count)
                var best = Double.infinity
                for run in runs {
                    // Distance to the run's box, not its centre: a region can be one word of it.
                    let xs = run.quad.map(\.x)
                    let ys = run.quad.map(\.y)
                    guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max()
                    else { continue }
                    best = min(best, hypot(max(x0 - cx, 0, cx - x1), max(y0 - cy, 0, cy - y1)))
                }
                if best.isFinite { offsets.append(best * 25.4 / 72) }
            }
            if !offsets.isEmpty {
                let sorted = offsets.sorted()
                let p90 = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
                print(
                    String(
                        format: "  accepted region's centre to the nearest text run's box (mm): "
                            + "median %.2f, 90th percentile %.2f, largest %.2f",
                        sorted[sorted.count / 2], p90, sorted[sorted.count - 1]))
            }
            for decision in accepted
            where agreement(decision.recognised ?? "", decision.readText ?? "") == .different {
                let ocr = decision.recognised ?? ""
                print("    differs: OCR \"\(ocr)\" page \"\(decision.readText ?? "")\"")
            }
        }

        static func list(_ report: PDF.ShapeTextReport) {
            for decision in report.decisions {
                let corner = decision.quad.first ?? .zero
                let outcome: String
                switch decision.outcome {
                case .accepted: outcome = "accepted"
                case .rejected(let reason): outcome = "rejected \(reason.rawValue)"
                }
                let confidence = decision.confidence.map { String(format: " %.2f", $0) } ?? ""
                let read = decision.readText.map { " page text \"\($0)\"" } ?? ""
                print(
                    String(
                        format: "    (%.0f, %.0f) glyphs %d: \"%@\"%@ %@", corner.x, corner.y,
                        decision.glyphs, decision.recognised ?? "-", confidence, outcome) + read)
            }
        }
    }
#endif
