// Dimensions.swift
// pdfprobe
//
// `pdfprobe dimensions` reports the dimensions and scale a PDF page gives, and the evidence for
// them. `pdfprobe dimension-pairs` (DimensionPairs.swift) checks them against the paired drawing.

import Foundation

#if os(macOS)
    import CoreGraphics
    import OCCTSwiftPDF

    /// What the command line says about the rebuild.
    struct DimensionFlags {
        var options = PDF.DimensionOptions()
        var detail = false
        /// The paths left after the flags.
        var paths: [String] = []

        init(_ arguments: [String]) {
            var rest = arguments[...]
            while let next = rest.popFirst() {
                switch next {
                case "--numbers":
                    switch rest.popFirst() {
                    case "thousands": options.numbers = .commaSeparatesThousands
                    case "decimal": options.numbers = .commaIsDecimalMark
                    case "plain": options.numbers = .plain
                    default: break
                    }
                case "--scale": options.scale = rest.popFirst().flatMap(Double.init)
                case "--tolerance": options.tolerance = rest.popFirst().flatMap(Double.init)
                case "--scale-range":
                    if let low = rest.popFirst().flatMap(Double.init),
                        let high = rest.popFirst().flatMap(Double.init), low <= high
                    {
                        options.scaleRange = low...high
                    }
                case "--no-views": options.separateViews = false
                case "--no-arrowheads": options.arrowheads = false
                case "--view-gap": options.viewGap = rest.popFirst().flatMap(Double.init)
                case "--detail": detail = true
                default: paths.append(next)
                }
            }
        }
    }

    /// `1:80` for a real value per paper millimetre of 80, and `2:1` for 0.5.
    func scaleText(_ scale: Double) -> String {
        func shown(_ value: Double) -> String {
            String(format: "%g", (value * 100).rounded() / 100)
        }
        return scale >= 1 ? "1:" + shown(scale) : shown(1 / scale) + ":1"
    }

    func unexplainedCount(_ recovery: PDF.DimensionRecovery) -> Int {
        recovery.warnings.filter {
            if case .valueNotExplained = $0 { return true }
            return false
        }.count
    }

    func dimensionLine(_ url: URL, _ flags: DimensionFlags) -> (
        line: String, recovery: PDF.DimensionRecovery?
    ) {
        let name = url.lastPathComponent
        guard let document = try? PDF.read(contentsOf: url, maximumPages: 1),
            let page = document.pages.first
        else { return ("\(name)\tcannot open", nil) }
        let recovery = page.recoveringDimensions(flags.options)
        let texts = page.texts.filter { !$0.isInvisible || $0.text != nil }.count
        var line = "\(name)\t\(page.kind.rawValue)\ttexts \(texts)\tviews \(recovery.views.count)"
        line += "\tdimensions \(recovery.dimensions.count)"
        line += "\tunexplained \(unexplainedCount(recovery))"
        if let sheet = recovery.sheet {
            line +=
                "\tscale \(scaleText(sheet.scale)) (+\(sheet.supporting)/-\(sheet.contradicting))"
        } else {
            line += "\tscale none"
        }
        let others = recovery.views.compactMap { view in
            view.alternative.map {
                "v\(view.number) \(scaleText($0.scale.scale)) (+\($0.scale.supporting)/-\($0.scale.contradicting))"
            }
        }
        if !others.isEmpty { line += "\tviews favour " + others.joined(separator: "; ") }
        return (line, recovery)
    }

    func dimensionsCommand(_ arguments: [String]) {
        let flags = DimensionFlags(arguments)
        var files = 0
        var withDimensions = 0
        var total = 0
        var scaled = 0
        var disagree = 0
        var unexplained = 0
        var scales: [String: Int] = [:]
        for url in pdfs(in: flags.paths) {
            let (line, recovery) = dimensionLine(url, flags)
            print(line)
            guard let recovery else { continue }
            files += 1
            total += recovery.dimensions.count
            unexplained += unexplainedCount(recovery)
            if !recovery.dimensions.isEmpty { withDimensions += 1 }
            if let scale = recovery.scale {
                scaled += 1
                scales[scaleText(scale), default: 0] += 1
            }
            if recovery.views.contains(where: { $0.alternative != nil }) { disagree += 1 }
            if flags.detail { printDetail(recovery) }
        }
        print(
            "\(files) pages read; with dimensions \(withDimensions); dimensions \(total); "
                + "with a scale for the sheet \(scaled); some view favours another scale \(disagree); "
                + "values unexplained \(unexplained)")
        let byCount = scales.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let listed = byCount.map { "\($0.key) \($0.value)" }
        print("scales: \(listed.joined(separator: ", "))")
    }

    func printDetail(_ recovery: PDF.DimensionRecovery) {
        for view in recovery.views {
            let scale = view.scale.map(scaleText) ?? "none"
            print(
                "  view \(view.number) at \(view.bounds.integral): scale \(scale), "
                    + "supporting \(view.supporting), contradicting \(view.contradicting)")
            for dimension in view.dimensions {
                let measured = dimension.measurement.map { String(format: "%.3f", $0) } ?? "-"
                print("    \(dimension.textOverride ?? "?") \(dimension.kind) measured \(measured)")
            }
            for warning in view.warnings { print("    warning: \(warning)") }
            if let other = view.alternative {
                print(
                    "    favours \(scaleText(other.scale.scale)) "
                        + "(+\(other.scale.supporting)/-\(other.scale.contradicting)), "
                        + "\(other.dimensions.count) dimensions")
            }
        }
    }
#endif
