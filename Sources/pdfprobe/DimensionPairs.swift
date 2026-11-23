// DimensionPairs.swift
// pdfprobe
//
// `pdfprobe dimension-pairs <folder>`: the dimensions and scale a PDF gives, against those of the
// drawing paired with it (a DXF, or a JWW where the DXF is missing). The reference is rebuilt the
// same way at its own full size, with the way Jw_cad writes numbers, placed on the paper by the
// comparison's fit, and the scale the fit found is the scale the sheet is at. Dimensions are
// compared by text and by the place of both ends on the paper, never by a picture.

import Foundation

#if os(macOS)
    import CoreGraphics
    import OCCTSwiftPDF
    import SwiftJWW

    /// The two points a dimension measures between, as a rebuild gives them.
    func ends(_ dimension: DXF.Dimension) -> (DXF.Point2, DXF.Point2)? {
        switch dimension.kind {
        case .linear, .aligned:
            guard let a = dimension.defPoint2, let b = dimension.defPoint3 else { return nil }
            return (DXF.Point2(a.x, a.y), DXF.Point2(b.x, b.y))
        default:
            guard let b = dimension.defPoint4 else { return nil }
            return (DXF.Point2(dimension.defPoint.x, dimension.defPoint.y), DXF.Point2(b.x, b.y))
        }
    }

    /// A text as a key: no spaces, so `1 600` and `1600` agree.
    func key(_ dimension: DXF.Dimension) -> String {
        (dimension.textOverride ?? "").filter { !$0.isWhitespace }
    }

    /// How the PDF's dimensions line up with the reference's, by text and by place on the paper.
    struct DimensionMatch {
        /// Same text, both ends within the tolerance.
        var matched = 0
        /// Same text but a different place, where no pair of that text matched: a dimension that
        /// is wrong, or that the reference has somewhere else.
        var moved = 0
        /// The PDF's, with no dimension of that text in the reference.
        var pdfOnly = 0
        /// The reference's, with no dimension of that text in the PDF.
        var referenceOnly = 0
        /// Of the `moved` and `pdfOnly` ones, those rebuilt at a scale other than the sheet's
        /// (within 1 percent), which cannot be right whatever the reference has.
        var wrongScale = 0
    }

    func matchDimensions(
        _ pdf: [DXF.Dimension], _ reference: [DXF.Dimension], tolerance: Double, known: Double,
        detail: Bool = false, place: (DXF.Point2) -> DXF.Point2
    ) -> DimensionMatch {
        var result = DimensionMatch()
        var free = Array(reference.indices)
        var unmatched: [DXF.Dimension] = []
        for dimension in pdf {
            guard let (a, b) = ends(dimension) else {
                unmatched.append(dimension)
                continue
            }
            let found = free.firstIndex { index in
                let other = reference[index]
                guard key(other) == key(dimension), let (c, d) = ends(other) else { return false }
                let (p, q) = (place(c), place(d))
                return (a.distance(to: p) <= tolerance && b.distance(to: q) <= tolerance)
                    || (a.distance(to: q) <= tolerance && b.distance(to: p) <= tolerance)
            }
            if let found {
                free.remove(at: found)
                result.matched += 1
            } else {
                unmatched.append(dimension)
            }
        }
        for dimension in unmatched {
            if let scale = dimension.rebuilt?.scale, abs(scale / known - 1) > 0.01 {
                result.wrongScale += 1
            }
            let length = dimension.measurement.map { String(format: "%.2f", $0) } ?? "-"
            if let found = free.firstIndex(where: { key(reference[$0]) == key(dimension) }) {
                free.remove(at: found)
                result.moved += 1
                if detail { print("    moved \(key(dimension)) (paper length \(length) mm)") }
            } else {
                result.pdfOnly += 1
                if detail { print("    PDF only \(key(dimension)) (paper length \(length) mm)") }
            }
        }
        result.referenceOnly = free.count
        if detail {
            for index in free {
                let length = reference[index].measurement.map { String(format: "%.2f", $0 / known) }
                print(
                    "    reference only \(key(reference[index])) (paper length \(length ?? "-") mm)"
                )
            }
        }
        return result
    }

    /// The texts of the dimensions SwiftJWW recovers from a JWW with Jw_cad's attribute flags, or
    /// `nil` when the reference is not a JWW.
    func flaggedTexts(_ reference: URL) -> [String]? {
        let name = reference.lastPathComponent.lowercased()
        guard name.contains("_jww.") || name.hasSuffix(".jww"),
            let data = try? jwwData(at: reference), let jww = try? JWW.read(data: data)
        else { return nil }
        return jww.recoveringDimensions().dimensions.map {
            $0.dimension.label.string.filter { !$0.isWhitespace }
        }
    }

    struct PairRow {
        var stem: String
        var known: Double?
        var found: Double?
        var viewsDisagree: Bool
        var pdfDimensions: Int
        var referenceDimensions: Int
        var match: DimensionMatch
        var pdfUnexplained: Int
        var referenceUnexplained: Int
        var flaggedTruth: Int?
        var flaggedShared: Int?
    }

    func dimensionPair(
        _ pdf: URL, _ reference: URL, _ flags: DimensionFlags, excluded: Set<String>
    ) -> PairRow? {
        guard let document = try? PDF.read(contentsOf: pdf, maximumPages: 1),
            let page = document.pages.first,
            var ref = try? referenceDrawing(at: reference)
        else { return nil }
        if !excluded.isEmpty {
            ref.entities.removeAll { excluded.contains(PDF.describe(layerOf: $0)) }
        }
        guard let fit = PDF.compare(page.drawing(), with: ref) else { return nil }
        let recovery = page.recoveringDimensions(flags.options)
        // The reference is read the way Jw_cad writes numbers, and at its own (full) size.
        let truth = ref.rebuildingDimensions(.init(numbers: .commaSeparatesThousands))
        let match = matchDimensions(
            recovery.dimensions, truth.dimensions, tolerance: 0.5, known: 1 / fit.scale,
            detail: flags.detail, place: fit.place)
        var row = PairRow(
            stem: pdf.deletingPathExtension().lastPathComponent, known: 1 / fit.scale,
            found: recovery.scale,
            viewsDisagree: recovery.views.contains { $0.alternative != nil },
            pdfDimensions: recovery.dimensions.count, referenceDimensions: truth.dimensions.count,
            match: match, pdfUnexplained: unexplainedCount(recovery),
            referenceUnexplained: unexplainedCount(truth.warnings))
        if let texts = flaggedTexts(reference) {
            var have: [String: Int] = [:]
            for dimension in recovery.dimensions { have[key(dimension), default: 0] += 1 }
            var shared = 0
            for text in texts where (have[text] ?? 0) > 0 {
                have[text, default: 0] -= 1
                shared += 1
            }
            row.flaggedTruth = texts.count
            row.flaggedShared = shared
        }
        return row
    }

    func dimensionPairsCommand(_ arguments: [String], excluded: Set<String>) {
        let flags = DimensionFlags(arguments)
        guard let first = flags.paths.first else { return }
        let folder = URL(fileURLWithPath: first)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var rows: [PairRow] = []
        var skipped = 0
        for file in files.sorted() where file.lowercased().hasSuffix(".pdf") {
            let stem = String(file.dropLast(4))
            guard let paired = pairedReference(folder, stem) else { continue }
            guard
                let row = dimensionPair(
                    folder.appendingPathComponent(file), paired, flags, excluded: excluded)
            else {
                skipped += 1
                continue
            }
            rows.append(row)
            let known = row.known.map(scaleText) ?? "?"
            var found = row.found.map(scaleText) ?? "none"
            if row.viewsDisagree { found += " (a view favours another)" }
            var line = "\(row.stem)\tknown \(known)\tfound \(found)"
            line += "\tPDF \(row.pdfDimensions)\treference \(row.referenceDimensions)"
            line += "\tmatched \(row.match.matched)\tmoved \(row.match.moved)"
            line += "\tPDF only \(row.match.pdfOnly)\treference only \(row.match.referenceOnly)"
            line += "\twrong scale \(row.match.wrongScale)"
            line += "\tunexplained PDF \(row.pdfUnexplained) reference \(row.referenceUnexplained)"
            if let truth = row.flaggedTruth, let shared = row.flaggedShared {
                line += "\tflagged \(truth) shared \(shared)"
            }
            print(line)
        }
        printDimensionSummary(rows, skipped: skipped)
    }

    func printDimensionSummary(_ rows: [PairRow], skipped: Int) {
        func sum(_ value: (PairRow) -> Int) -> Int { rows.reduce(0) { $0 + value($1) } }
        let pdf = sum { $0.pdfDimensions }
        let reference = sum { $0.referenceDimensions }
        let matched = sum { $0.match.matched }
        print("pairs compared \(rows.count); not compared \(skipped)")
        print(
            "dimensions: PDF \(pdf), reference \(reference), matched \(matched), "
                + "moved \(sum { $0.match.moved }), PDF only \(sum { $0.match.pdfOnly }), "
                + "reference only \(sum { $0.match.referenceOnly }); of the moved and PDF only, "
                + "\(sum { $0.match.wrongScale }) at a scale other than the fit's")
        if pdf > 0, reference > 0 {
            print(
                String(
                    format: "matched is %.1f%% of the PDF's and %.1f%% of the reference's",
                    100 * Double(matched) / Double(pdf), 100 * Double(matched) / Double(reference)))
        }
        let withDimensions = rows.filter { $0.referenceDimensions > 0 }
        print("sheets whose reference has dimensions: \(withDimensions.count)")
        var agree = 0
        var wrong = 0
        var none = 0
        var disagree = 0
        for row in withDimensions {
            guard let known = row.known else { continue }
            if let found = row.found {
                if abs(found / known - 1) <= 0.01 { agree += 1 } else { wrong += 1 }
            } else {
                none += 1
            }
            if row.viewsDisagree { disagree += 1 }
        }
        print(
            "scale on those: equal to the fit's (within 1%) \(agree), different \(wrong), "
                + "none found \(none); a view favours another scale on \(disagree)")
        let truth = rows.compactMap(\.flaggedTruth).reduce(0, +)
        let shared = rows.compactMap(\.flaggedShared).reduce(0, +)
        if truth > 0 {
            print(
                "against Jw_cad's flags (JWW): \(truth) dimensions, \(shared) of their texts found")
        }
        let exact = withDimensions.filter {
            $0.match.moved == 0 && $0.match.pdfOnly == 0 && $0.match.referenceOnly == 0
        }
        print("sheets where the two agree exactly: \(exact.count) of \(withDimensions.count)")
    }
#endif
