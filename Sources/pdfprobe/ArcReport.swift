// ArcReport.swift
// pdfprobe
//
// `pdfprobe arcs`: the circles and arcs recovered from each PDF, counted by the producer that wrote
// the file, with how well each fits.

#if os(macOS)
    import Foundation
    import OCCTSwiftPDF
    import SwiftDXF

    /// What recovery found in one file.
    struct ArcFileResult {
        var name: String
        var producer: String
        var pages: Int
        var fits: [PDF.ArcFit] = []
        var curvesReplaced = 0
        var linesReplaced = 0
        /// The default drawing's curve and polyline-vertex counts, to show what the fits came from.
        var splines = 0
        var polylines = 0
        var lines = 0
        /// Pairs of arcs on one page that meet end to start on the same circle: a circle or arc
        /// that the writer split between paths, or subpaths, and recovery did not join.
        var joinable = 0
    }

    /// The number of pairs of arcs, one ending where the other starts, on the same circle within
    /// 0.02 mm (or 0.04 percent of the radius) of centre and radius.
    func joinablePairs(_ fits: [PDF.ArcFit]) -> Int {
        func end(_ fit: PDF.ArcFit, _ degrees: Double) -> (Double, Double) {
            let a = degrees * .pi / 180
            return (fit.center.x + fit.radius * cos(a), fit.center.y + fit.radius * sin(a))
        }
        let arcs = fits.filter { $0.shape == .arc }
        var cells: [String: [Int]] = [:]
        func key(_ x: Double, _ y: Double) -> String {
            "\(Int((x / 0.5).rounded(.down)))/\(Int((y / 0.5).rounded(.down)))"
        }
        for (index, fit) in arcs.enumerated() {
            let (x, y) = end(fit, fit.endDeg)
            cells[key(x, y), default: []].append(index)
        }
        var pairs = 0
        for (index, fit) in arcs.enumerated() {
            let (sx, sy) = end(fit, fit.startDeg)
            let cx = Int((sx / 0.5).rounded(.down))
            let cy = Int((sy / 0.5).rounded(.down))
            for dx in -1...1 {
                for dy in -1...1 {
                    for other in cells["\(cx + dx)/\(cy + dy)"] ?? [] where other != index {
                        let g = arcs[other]
                        let (ex, ey) = end(g, g.endDeg)
                        let tolerance = 0.02 + 0.0004 * fit.radius
                        let sameCircle =
                            hypot(fit.center.x - g.center.x, fit.center.y - g.center.y)
                            <= tolerance && abs(fit.radius - g.radius) <= tolerance
                        if sameCircle && hypot(sx - ex, sy - ey) <= tolerance { pairs += 1 }
                    }
                }
            }
        }
        return pairs
    }

    func producerName(_ document: PDF.Document) -> String {
        let raw = document.producer ?? document.creator ?? "(none)"
        // Versions and build numbers vary file to file inside one writer.
        let words = raw.split(separator: " ").prefix { !($0.first?.isNumber ?? false) }
        let name = words.joined(separator: " ")
        return name.isEmpty ? raw : name
    }

    func arcResult(_ url: URL, _ options: PDF.ArcFitting) -> ArcFileResult? {
        guard let document = try? PDF.read(contentsOf: url) else { return nil }
        var result = ArcFileResult(
            name: url.lastPathComponent, producer: producerName(document),
            pages: document.pages.count)
        for page in document.pages {
            let fitted = page.fittedDrawing(options)
            result.fits += fitted.fits
            result.curvesReplaced += fitted.curvesReplaced
            result.linesReplaced += fitted.linesReplaced
            result.splines += fitted.drawing.counts.spline
            result.polylines += fitted.drawing.counts.polyline
            result.lines += fitted.drawing.counts.line
            result.joinable += joinablePairs(fitted.fits)
        }
        return result
    }

    func arcLine(_ r: ArcFileResult) -> String {
        let circles = r.fits.filter { $0.shape == .circle }
        let arcs = r.fits.filter { $0.shape == .arc }
        func inputs(_ fits: [PDF.ArcFit]) -> String {
            let by = Dictionary(grouping: fits, by: \.input).mapValues(\.count)
            return "curves \(by[.curves] ?? 0), lines \(by[.lines] ?? 0), mixed \(by[.mixed] ?? 0)"
        }
        let worst = r.fits.map(\.maxResidual).max() ?? 0
        return
            "\(r.name)\t\(r.producer)\tpages \(r.pages)\tcircles \(circles.count) (\(inputs(circles)))"
            + "\tarcs \(arcs.count) (\(inputs(arcs)))\treplaced curves \(r.curvesReplaced), lines "
            + "\(r.linesReplaced)\tleft: splines \(r.splines), polylines \(r.polylines)"
            + String(format: "\tworst residual %.4f mm", worst) + "\tjoinable \(r.joinable)"
    }

    func printArcFit(_ fit: PDF.ArcFit) {
        print(
            String(
                format:
                    "    %@ r %.4f at (%.3f, %.3f) from %.2f to %.2f  max %.5f rms %.5f  %@ x%d  %@",
                fit.shape.rawValue, fit.radius, fit.center.x, fit.center.y, fit.startDeg,
                fit.endDeg, fit.maxResidual, fit.rmsResidual, fit.input.rawValue, fit.segments,
                fit.sources.map(\.description).joined(separator: ",")))
    }

    /// The per-producer table: files, files with a fit, circles and arcs by input, and the
    /// residuals.
    func printArcSummary(_ results: [ArcFileResult]) {
        let byProducer = Dictionary(grouping: results, by: \.producer)
        print("\nper producer (files, files with fits, circles, arcs; from curves / lines / mixed)")
        for (producer, files) in byProducer.sorted(by: { $0.key < $1.key }) {
            let fits = files.flatMap(\.fits)
            let circles = fits.filter { $0.shape == .circle }
            let arcs = fits.filter { $0.shape == .arc }
            func split(_ list: [PDF.ArcFit]) -> String {
                let by = Dictionary(grouping: list, by: \.input).mapValues(\.count)
                return "\(by[.curves] ?? 0)/\(by[.lines] ?? 0)/\(by[.mixed] ?? 0)"
            }
            let residuals = fits.map(\.maxResidual).sorted()
            let median = residuals.isEmpty ? 0 : residuals[residuals.count / 2]
            print(
                "  \(producer): files \(files.count), with fits \(files.filter { !$0.fits.isEmpty }.count),"
                    + " circles \(circles.count) (\(split(circles))), arcs \(arcs.count) (\(split(arcs))),"
                    + " curves replaced \(files.reduce(0) { $0 + $1.curvesReplaced }),"
                    + " lines replaced \(files.reduce(0) { $0 + $1.linesReplaced }),"
                    + String(
                        format: " residual median %.4f max %.4f mm", median, residuals.last ?? 0)
                    + ", joinable pairs \(files.reduce(0) { $0 + $1.joinable })")
        }
        let all = results.flatMap(\.fits)
        print(
            "total: \(results.count) files, \(results.filter { !$0.fits.isEmpty }.count) with fits, "
                + "circles \(all.filter { $0.shape == .circle }.count), "
                + "arcs \(all.filter { $0.shape == .arc }.count), "
                + "joinable pairs \(results.reduce(0) { $0 + $1.joinable })")
    }

    /// One pair's recovered circles and arcs against the reference's.
    struct ArcPairResult {
        var name: String
        var producer: String
        var scale: Double
        var fits: [PDF.ArcFit]
        var comparison: PDF.ArcComparison
        var matches: [PDF.ArcMatch] { comparison.matches }
    }

    func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
    }

    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// `pdfprobe arc-pairs <folder>`: for each PDF beside a DXF (or a JWW) of the same drawing,
    /// the recovered circles and arcs against the reference's, by coordinates.
    ///
    /// Placing a reference takes minutes over the whole folder and does not depend on the options
    /// under test, so with `PDFPROBE_PLACEMENTS` set to a file path the placements are kept there
    /// and read back on the next run.
    func arcPairs(
        _ folder: URL, _ options: PDF.ArcFitting, excluded: Set<String>, detail: Bool,
        bound: Double, table: String? = nil
    ) -> [ArcPairResult] {
        var rows: [String] = []
        defer {
            if let table {
                let head =
                    "file\tproducer\tmatched\tshape\tinput\tsegments\tsweep\tradius"
                    + "\tmax\trms\tstepRatio\tradiusError\tcentreError\tendpointError\tscale\tsupport\tmarker"
                try? ([head] + rows).joined(separator: "\n").write(
                    toFile: table, atomically: true, encoding: .utf8)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var results: [ArcPairResult] = []
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
        defer {
            if let cachePath {
                let text = placements.sorted { $0.key < $1.key }.map {
                    "\($0.key)\t\($0.value.scale)\t\($0.value.rotationDeg)"
                        + "\t\($0.value.translationX)\t\($0.value.translationY)"
                }.joined(separator: "\n")
                try? text.write(toFile: cachePath, atomically: true, encoding: .utf8)
            }
        }
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
            let fitted = page.fittedDrawing(options)
            // Placed by the default drawing, as `pairs` does, so the placement does not depend on
            // the options being tried.
            let placement: PDF.Placement
            if let kept = placements[file] {
                placement = kept
            } else if let made = PDF.compare(page.drawing(), with: reference) {
                placement = made.placement
                placements[file] = placement
            } else {
                continue
            }
            let comparison = PDF.compareArcs(
                fitted, with: reference, placedBy: placement, within: bound)
            let result = ArcPairResult(
                name: file, producer: producerName(document), scale: placement.scale,
                fits: fitted.fits, comparison: comparison)
            results.append(result)
            let errors = result.matches.map { abs($0.radiusError) / placement.scale }
            let scale = String(format: "%.5f", placement.scale)
            let worst = String(
                format: "median %.4f max %.4f", median(of: errors), errors.max() ?? 0)
            print(
                "\(file)\t\(result.producer)\tscale \(scale)"
                    + "\treference circles+arcs \(comparison.referenceCount)\tfits \(fitted.fits.count)"
                    + "\tmatched \(result.matches.count)"
                    + "\tpoint markers \(comparison.pointMarkers.count)"
                    + "\tunmatched fits \(comparison.unmatchedFits.count)"
                    + "\tunmatched reference \(comparison.unmatchedReference.count)"
                    + "\tfull-size radius error \(worst)")
            if table != nil {
                var byFit: [Int: PDF.ArcMatch] = [:]
                for match in comparison.matches { byFit[match.fit] = match }
                for (position, fit) in fitted.fits.enumerated() {
                    let match = byFit[position]
                    let fields: [String] = [
                        file, result.producer, match == nil ? "0" : "1", fit.shape.rawValue,
                        fit.input.rawValue, "\(fit.segments)", "\(fit.sweepDeg)", "\(fit.radius)",
                        "\(fit.maxResidual)", "\(fit.rmsResidual)", "\(fit.stepRatio)",
                        match.map { "\($0.radiusError)" } ?? "",
                        match.map { "\($0.centreError)" } ?? "",
                        match?.endpointError.map { "\($0)" } ?? "", "\(placement.scale)",
                        "\(comparison.support[position])",
                        comparison.pointMarkers.contains(position) ? "1" : "0",
                    ]
                    rows.append(fields.joined(separator: "\t"))
                }
            }
            if detail {
                for position in comparison.unmatchedFits {
                    print("    unmatched ", terminator: "")
                    printArcFit(fitted.fits[position])
                }
                for round in comparison.unmatchedReference {
                    let span = round.spanDeg.map {
                        String(format: " from %.1f to %.1f", $0[0], $0[1])
                    }
                    print(
                        String(
                            format: "    missed reference r %.4f at (%.3f, %.3f)%@",
                            round.radius, round.center.x, round.center.y, span ?? " (circle)"))
                }
                for match in comparison.matches {
                    let fit = fitted.fits[match.fit]
                    let end = match.endpointError.map { String(format: "%.3f", $0) } ?? "-"
                    print(
                        String(
                            format:
                                "    matched %@ x%d r %.4f (paper) reference r %.4f %@ radius error %.4f centre error %.4f endpoints %@ %@ %@ width %.4f",
                            fit.shape.rawValue, fit.segments, fit.radius,
                            fit.radius - match.radiusError,
                            match.referenceIsCircle ? "circle" : "arc", match.radiusError,
                            match.centreError, end, fit.input.rawValue,
                            fit.sources.map(\.description).joined(separator: ","), fit.lineWidth))
                }
            }
        }
        return results
    }

    /// The totals over every pair: how many fits the reference confirms, the errors of those that
    /// it does, in millimetres on the paper and at full size (reference units), and the circles
    /// and arcs of the reference that no fit matched.
    func printArcPairSummary(_ results: [ArcPairResult]) {
        func spread(_ label: String, _ paper: [Double], _ full: [Double]) {
            let first = String(
                format: "median %.4f p90 %.4f max %.4f", median(of: paper), percentile(paper, 0.9),
                paper.max() ?? 0)
            let second = String(
                format: "median %.4f p90 %.4f max %.4f", median(of: full), percentile(full, 0.9),
                full.max() ?? 0)
            print("  \(label) on the paper (mm): \(first); at full size: \(second)")
        }
        func block(_ title: String, _ list: [ArcPairResult]) {
            let fits = list.reduce(0) { $0 + $1.fits.count }
            let matched = list.flatMap { r in r.matches.map { (r, $0) } }
            let unmatchedFits = list.reduce(0) { $0 + $1.comparison.unmatchedFits.count }
            let markers = list.reduce(0) { $0 + $1.comparison.pointMarkers.count }
            let reference = list.reduce(0) { $0 + $1.comparison.referenceCount }
            let missed = list.reduce(0) { $0 + $1.comparison.unmatchedReference.count }
            print(
                "\(title): pairs \(list.count), fits \(fits), matched \(matched.count), "
                    + "circles on a reference point \(markers), unmatched fits \(unmatchedFits)")
            print("  reference circles+arcs \(reference), with no fit \(missed)")
            spread(
                "radius error", matched.map { abs($0.1.radiusError) },
                matched.map { abs($0.1.radiusError) / $0.0.scale })
            spread(
                "centre error", matched.map { $0.1.centreError },
                matched.map { $0.1.centreError / $0.0.scale })
            let relative = matched.map {
                abs($0.1.radiusError) / max($0.0.fits[$0.1.fit].radius, 1e-9)
            }
            let share = String(
                format: "median %.5f p90 %.5f max %.5f", median(of: relative),
                percentile(relative, 0.9), relative.max() ?? 0)
            print("  radius error as a fraction of the radius: \(share)")
        }
        block("all", results)
        for (producer, list) in Dictionary(grouping: results, by: \.producer).sorted(by: {
            $0.key < $1.key
        }) {
            block(producer, list)
        }
    }
#endif
