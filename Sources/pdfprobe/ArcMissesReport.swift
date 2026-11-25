// ArcMissesReport.swift
// pdfprobe
//
// `pdfprobe arc-misses`: for each PDF beside a DXF (or a JWW) of the same drawing, the reference's
// circles and arcs that no fit matched, with what the reference has at their ends and what the PDF
// drew along them, and a table of every fit with what the PDF has at its ends.

#if os(macOS)
    import Foundation
    import OCCTSwiftPDF
    import SwiftDXF

    /// `pdfprobe arc-misses [--bound <mm>] [--misses <file>] [--fits <file>] <folder>`.
    ///
    /// Reads the placements `arc-pairs` keeps with `PDFPROBE_PLACEMENTS`, and adds to that file the
    /// ones it has to make.
    func arcMisses(
        _ folder: URL, _ options: PDF.ArcFitting, excluded: Set<String>, bound: Double,
        missesPath: String?, fitsPath: String?, look: (file: String, refs: Set<Int>)? = nil
    ) {
        var missRows: [String] = [
            "file\tproducer\tscale\tref\tshape\tradius\tsweep\trefMet\trefTan\tpdfMet\tpdfTan"
                + "\tsupport\tcovered\tcurves\tlines\twidest\trun\tlayer"
        ]
        var fitRows: [String] = [
            "file\tproducer\tscale\tmatched\tshape\tinput\tsegments\tsweep\tradius\tmax\trms"
                + "\tstepRatio\tsupport\tpdfMet\tpdfTan"
        ]
        let cachePath = ProcessInfo.processInfo.environment["PDFPROBE_PLACEMENTS"]
        var placements: [String: PDF.Placement] = [:]
        if let cachePath, let text = try? String(contentsOfFile: cachePath, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t").map(String.init)
                if f.count == 5, let a = Double(f[1]), let b = Double(f[2]), let c = Double(f[3]),
                    let d = Double(f[4])
                {
                    placements[f[0]] = PDF.Placement(
                        scale: a, rotationDeg: b, translationX: c, translationY: d)
                }
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var pairs = 0
        for file in files.sorted() where file.lowercased().hasSuffix(".pdf") {
            let stem = String(file.dropLast(4))
            guard let paired = pairedReference(folder, stem),
                let document = try? PDF.read(
                    contentsOf: folder.appendingPathComponent(file), maximumPages: 1),
                let page = document.pages.first,
                var reference = try? referenceDrawing(at: paired)
            else { continue }
            if !excluded.isEmpty {
                reference.entities.removeAll { excluded.contains(PDF.describe(layerOf: $0)) }
            }
            let sizes = [folder.appendingPathComponent(file), paired].map {
                ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int) ?? 0
            }
            let key =
                "\(folder.path)/\(file)|\(sizes[0])|\(sizes[1])|\(excluded.sorted().joined(separator: ","))"
            let placement: PDF.Placement
            if let kept = placements[key] {
                placement = kept
            } else {
                // Not cached: leave the pair out, so that this run never costs minutes.
                continue
            }
            pairs += 1
            if let look, look.file != file { continue }
            let fitted = page.fittedDrawing(options)
            let comparison = PDF.compareArcs(
                fitted, with: reference, placedBy: placement, within: bound)
            if let look {
                for round in comparison.unmatchedReference where look.refs.contains(round.index) {
                    lookAround(page, round)
                }
                continue
            }
            let producer = producerName(document)
            let scale = String(format: "%.6f", placement.scale)
            for miss in PDF.missedArcs(
                on: page, comparison: comparison, reference: reference, placedBy: placement)
            {
                let fields: [String] = [
                    file, producer, scale, "\(miss.reference)", miss.isCircle ? "circle" : "arc",
                    String(format: "%.4f", miss.radius), String(format: "%.2f", miss.sweepDeg),
                    "\(miss.referenceContacts.met)", "\(miss.referenceContacts.tangent)",
                    "\(miss.pdfContacts.met)", "\(miss.pdfContacts.tangent)",
                    String(format: "%.3f", miss.support), String(format: "%.3f", miss.covered),
                    "\(miss.curves)", "\(miss.lines)", String(format: "%.2f", miss.widestPiece),
                    "\(miss.longestRun)", PDF.describe(layerOf: reference.entities[miss.reference]),
                ]
                missRows.append(fields.joined(separator: "\t"))
            }
            let contacts = PDF.fitContacts(fitted, on: page)
            var byFit: [Int: PDF.ArcMatch] = [:]
            for match in comparison.matches { byFit[match.fit] = match }
            for (position, fit) in fitted.fits.enumerated() {
                let state =
                    byFit[position] != nil
                    ? "1" : (comparison.pointMarkers.contains(position) ? "2" : "0")
                let fields: [String] = [
                    file, producer, scale, state, fit.shape.rawValue, fit.input.rawValue,
                    "\(fit.segments)", String(format: "%.3f", fit.sweepDeg),
                    String(format: "%.4f", fit.radius), String(format: "%.5f", fit.maxResidual),
                    String(format: "%.5f", fit.rmsResidual), String(format: "%.3f", fit.stepRatio),
                    String(format: "%.3f", comparison.support[position]),
                    "\(contacts[position].met)", "\(contacts[position].tangent)",
                ]
                fitRows.append(fields.joined(separator: "\t"))
            }
        }
        if look != nil { return }
        if let missesPath {
            try? missRows.joined(separator: "\n").write(
                toFile: missesPath, atomically: true, encoding: .utf8)
        }
        if let fitsPath {
            try? fitRows.joined(separator: "\n").write(
                toFile: fitsPath, atomically: true, encoding: .utf8)
        }
        print("arc-misses: \(pairs) pairs, \(missRows.count - 1) missed, \(fitRows.count - 1) fits")
    }

    /// What the page's drawing has along the circle or arc `round`: each piece with a vertex
    /// within 0.3 mm of the circle, with its vertices' distances from the circle and positions
    /// along the span.
    func lookAround(_ page: PDF.Page, _ round: PDF.ReferenceRound) {
        let cx = round.center.x
        let cy = round.center.y
        let r = round.radius
        let start = round.spanDeg?[0] ?? 0
        var sweep = 360.0
        if let span = round.spanDeg {
            sweep = (span[1] - span[0]).truncatingRemainder(dividingBy: 360)
            if sweep <= 0 { sweep += 360 }
        }
        print(
            String(
                format: "ref %d: centre (%.3f, %.3f) r %.4f from %.2f sweep %.2f", round.index, cx,
                cy, r, start, sweep))
        for (index, entity) in page.drawing().entities.enumerated() {
            var points: [(Double, Double)] = []
            var kind = ""
            switch entity {
            case .line(let a, let b, _, _):
                kind = "line"
                points = [(a.x, a.y), (b.x, b.y)]
            case .polyline(let vertices, _, _, _):
                kind = "polyline \(vertices.count)"
                points = vertices.map { ($0.point.x, $0.point.y) }
            case .spline(let spline):
                kind = "spline"
                points = spline.flattened(tolerance: 0.01).map { ($0.x, $0.y) }
            default:
                continue
            }
            let samples: [(d: Double, offset: Double)] = points.map { p in
                let d = hypot(p.0 - cx, p.1 - cy) - r
                var offset = atan2(p.1 - cy, p.0 - cx) * 180 / Double.pi - start
                offset = offset.truncatingRemainder(dividingBy: 360)
                if offset < 0 { offset += 360 }
                if offset > 359 { offset -= 360 }
                return (d, offset)
            }
            guard samples.contains(where: { abs($0.d) <= 0.3 && $0.offset <= sweep + 2 }) else {
                continue
            }
            let shown = samples.prefix(14).map { String(format: "%.3f@%.1f", $0.d, $0.offset) }
            let more = samples.count > 14 ? " ... (\(samples.count))" : ""
            print("  [\(index)] \(kind): \(shown.joined(separator: " "))\(more)")
        }
    }
#endif
