// ShapeTextRecovery.swift
// OCCTSwiftPDF
//
// Text drawn as shapes, recovered by OCR where the result agrees with the geometry: some writers
// draw text as filled outlines or strokes (Microsoft Print to PDF, Acrobat PDFWriter's UK railway
// sheets, AutoCAD's SHX text), so the page has no text to read. This is the first piece of the
// raster path. It is opt-in: nothing here runs, and Vision is not touched, unless asked.
//
// The seam, in order: find the lines of small shapes that might be text (ShapeTextRegions),
// render the page and cut each line out upright (ShapeTextRenderer), recognise it
// (TextRecogniser), validate what was recognised against the shapes (ShapeTextValidator), and emit
// the text that passes as runs marked `.ocr`.

import CoreGraphics
import Foundation

/// The first failure of the recogniser on a page, for the report.
private final class FirstFailure {
    var message: String?
}

/// What one reading of a region gave, and was accepted.
private struct ShapeTextReading {
    var text: String
    var confidence: Double
    var region: ShapeTextRegion
}

extension PDF.Document {
    /// The document with text drawn as shapes recovered by OCR where it agrees with the geometry.
    ///
    /// Each page is rendered, the lines of small filled or stroked shapes that might be text are
    /// found from the geometry already read, Apple Vision recognises each, and the result is
    /// accepted only where its position, direction and height agree with the shapes and its
    /// characters are plausible for their number (see ``PDF/ShapeTextOptions``). Accepted text is
    /// added to the page's `texts` as runs decoded ``PDF/TextDecoding/ocr`` with their
    /// ``PDF/TextRun/confidence``; everything else is counted in the page's report, with why.
    /// `drawing()` on a recovered page then draws the OCR text; the filled shapes it came from
    /// stay in `skipped["FILL"]` and the stroked ones are counted in `skipped["OCR TEXT"]`.
    ///
    /// Nothing calls Vision except this. It is synchronous and cannot be cancelled or report
    /// progress, and a sheet takes a while: about a minute for a thousand clusters, minutes for a
    /// large sheet with a great deal of outlined text (three readings of every cluster, and the
    /// page is rendered in tiles for each), and the first recognition after a boot takes about
    /// half a minute longer while the system loads its model. Call it off the main thread.
    ///
    /// - Throws: ``PDF/Error/cannotOpen`` where the file cannot be opened again, and
    ///   ``PDF/RecognitionError/unavailable`` where the platform has no Vision.
    public func recoveringShapeText(options: PDF.ShapeTextOptions = .init()) throws
        -> PDF.ShapeTextRecovery
    {
        #if canImport(Vision)
            return try recoveringShapeText(options: options, recogniser: VisionTextRecogniser())
        #else
            throw PDF.RecognitionError.unavailable
        #endif
    }

    func recoveringShapeText(options: PDF.ShapeTextOptions, recogniser: some TextRecogniser) throws
        -> PDF.ShapeTextRecovery
    {
        guard let file = CGPDFDocument(url as CFURL) else { throw PDF.Error.cannotOpen }
        if file.isEncrypted && !file.isUnlocked && !file.unlockWithPassword("") {
            throw PDF.Error.cannotOpen
        }
        var document = self
        var reports: [Int: PDF.ShapeTextReport] = [:]
        for index in document.pages.indices {
            let page = document.pages[index]
            guard let source = file.page(at: page.number) else { continue }
            let recovered = try page.recoveringShapeText(
                from: source, options: options, recogniser: recogniser)
            document.pages[index] = recovered.page
            reports[page.number] = recovered.report
        }
        return PDF.ShapeTextRecovery(document: document, reports: reports)
    }
}

extension PDF.Page {
    /// The page with text drawn as shapes recovered by OCR where it agrees with the geometry, and
    /// what was decided about every line of shapes looked at.
    ///
    /// `source` is this page in the file, which is rendered; see
    /// ``PDF/Document/recoveringShapeText(options:)``.
    public func recoveringShapeText(
        from source: CGPDFPage, options: PDF.ShapeTextOptions = .init()
    ) throws -> (page: PDF.Page, report: PDF.ShapeTextReport) {
        #if canImport(Vision)
            return try recoveringShapeText(
                from: source, options: options, recogniser: VisionTextRecogniser())
        #else
            throw PDF.RecognitionError.unavailable
        #endif
    }

    func recoveringShapeText(
        from source: CGPDFPage, options: PDF.ShapeTextOptions, recogniser: some TextRecogniser
    ) throws -> (page: PDF.Page, report: PDF.ShapeTextReport) {
        let found = ShapeTextRegions.find(in: self, options: options)
        let regions = found.regions
        let failures = FirstFailure()
        var report = PDF.ShapeTextReport(
            page: number, shapes: found.shapes, shapesInDenseBlobs: found.shapesInDenseBlobs,
            regions: regions.count, tooSmall: found.tooSmall, accepted: 0, rejected: [:],
            decisions: [])

        // What each region came to; nil until decided.
        var decided: [(decision: PDF.ShapeTextDecision, accepted: ShapeTextRegion?)?] =
            Array(repeating: nil, count: regions.count)
        func decide(
            _ index: Int, _ outcome: PDF.ShapeTextOutcome, text: String? = nil,
            confidence: Double? = nil, read: String? = nil, accepted: ShapeTextRegion? = nil
        ) {
            decided[index] = (
                PDF.ShapeTextDecision(
                    quad: regions[index].quad, glyphs: regions[index].glyphs, recognised: text,
                    confidence: confidence, outcome: outcome, readText: read), accepted
            )
        }

        // Regions the page already has text over are left alone, or recognised for comparison.
        let covering = TextCoverage(texts)
        var read: [Int: String] = [:]
        var queue: [Int] = []
        for (index, region) in regions.enumerated() {
            if let text = covering.text(over: region) {
                if options.existingText == .skip {
                    decide(index, .rejected(.alreadyRead), read: text)
                    continue
                }
                read[index] = text
            }
            if queue.count < options.maximumRegions {
                queue.append(index)
            } else {
                decide(index, .rejected(.overBudget))
            }
        }

        // Render, recognise, validate, once for each reading height. A region goes on to the next
        // reading only if this one accepted it, and is accepted in the end only if every reading
        // did and they read the same characters the same way up.
        var readings: [Int: ShapeTextReading] = [:]
        var active = queue
        for pixels in options.readingPixels.isEmpty ? [40] : options.readingPixels {
            var next: [Int] = []
            var reached: Set<Int> = []
            ShapeTextRenderer.tiles(
                for: active.map { regions[$0] }, page: source, glyphPixels: pixels
            ) { tile, local in
                for position in local {
                    let index = active[position]
                    reached.insert(index)
                    let attempt = Self.attempt(
                        regions[index], in: tile, options: options, recogniser: recogniser,
                        failures: failures)
                    switch (attempt.verdict, readings[index]) {
                    case (.accepted(let text, let confidence), nil):
                        readings[index] = ShapeTextReading(
                            text: text, confidence: confidence, region: attempt.region)
                        next.append(index)
                    case (.accepted(let text, let confidence), let before?):
                        let same =
                            Self.characters(text) == Self.characters(before.text)
                            && attempt.region.direction == before.region.direction
                        if same {
                            readings[index]?.confidence = min(before.confidence, confidence)
                            next.append(index)
                        } else {
                            decide(
                                index, .rejected(.inconsistent), text: before.text,
                                read: read[index])
                        }
                    case (.rejected(let reason, _), let before?):
                        // An earlier reading passed, so a validation failure now is a
                        // disagreement; a recogniser or render failure is reported as itself.
                        let failed = reason == .recognitionFailed || reason == .notRendered
                        decide(
                            index, .rejected(failed ? reason : .inconsistent), text: before.text,
                            read: read[index])
                    case (.rejected(let reason, let text), nil):
                        decide(index, .rejected(reason), text: text, read: read[index])
                    }
                }
            }
            for index in active where !reached.contains(index) {
                decide(index, .rejected(.notRendered), read: read[index])
            }
            active = next
        }
        for index in active {
            guard let reading = readings[index] else { continue }
            // Text the page already has is only compared, never added.
            decide(
                index, .accepted, text: reading.text, confidence: reading.confidence,
                read: read[index], accepted: read[index] == nil ? reading.region : nil)
        }
        for index in regions.indices where decided[index] == nil {
            decide(index, .rejected(.notRendered), read: read[index])
        }

        // Emit, and report.
        var texts = self.texts
        for case let entry? in decided {
            report.decisions.append(entry.decision)
            switch entry.decision.outcome {
            case .accepted: report.accepted += 1
            case .rejected(let reason): report.rejected[reason, default: 0] += 1
            }
            if let region = entry.accepted, let text = entry.decision.recognised,
                let confidence = entry.decision.confidence
            {
                texts.append(run(for: region, text: text, confidence: confidence))
            }
        }
        report.recognitionError = failures.message
        var page = self
        page.texts = texts
        return (page, report)
    }

    /// A recognised string without its spaces, for comparing two readings of one region.
    private static func characters(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// What recognising a region gives: tried as it reads, and, if the first fails, the other way
    /// round where it may run up or down a sheet, or where the recogniser read it but running the
    /// other way (upside down).
    private static func attempt(
        _ region: ShapeTextRegion, in tile: ShapeTextTile, options: PDF.ShapeTextOptions,
        recogniser: some TextRecogniser, failures: FirstFailure
    ) -> (verdict: ShapeTextValidator.Verdict, region: ShapeTextRegion) {
        var first: ShapeTextValidator.Verdict?
        var candidates = [region]
        while let candidate = candidates.first {
            candidates.removeFirst()
            let padding = ShapeTextRenderer.padding(for: candidate, scale: tile.scale)
            let verdict = read(candidate, in: tile, padding: padding, options, recogniser, failures)
            if case .accepted = verdict { return (verdict, candidate) }
            guard let earlier = first else {
                first = verdict
                var upsideDown = false
                if case .rejected(.direction, _) = verdict { upsideDown = true }
                if region.canReverse || upsideDown { candidates.append(region.reversed) }
                continue
            }
            // Both ways failed. Where the first was only the wrong way up, the second is the
            // reading that says why the text was refused.
            if case .rejected(.direction, _) = earlier { first = verdict }
        }
        return (first ?? .rejected(.notRendered, text: nil), region)
    }

    /// The verdict on one reading of a region.
    private static func read(
        _ region: ShapeTextRegion, in tile: ShapeTextTile, padding: Double,
        _ options: PDF.ShapeTextOptions, _ recogniser: some TextRecogniser,
        _ failures: FirstFailure
    ) -> ShapeTextValidator.Verdict {
        guard let crop = tile.crop(region, padding: padding) else {
            return .rejected(.notRendered, text: nil)
        }
        do {
            let lines = try recogniser.lines(in: crop.image).map { line in
                FramedLine(
                    text: line.text, confidence: line.confidence,
                    corners: line.corners.map {
                        let framed = crop.frame($0)
                        return CGPoint(x: framed.a, y: framed.b)
                    })
            }
            return ShapeTextValidator.validate(lines, in: region, options: options)
        } catch {
            if failures.message == nil {
                if case PDF.RecognitionError.failed(let message) = error {
                    failures.message = message
                } else {
                    failures.message = "\(error)"
                }
            }
            return .rejected(.recognitionFailed, text: nil)
        }
    }

    /// The OCR run for an accepted region: placed by the shapes, not by the recogniser's box, with
    /// its baseline where most of the glyphs stand and its height measured up from there.
    private func run(for region: ShapeTextRegion, text: String, confidence: Double) -> PDF.TextRun {
        let sources = region.paths.map { paths[$0].source }
        let first = sources.first ?? PDF.Source(page: number, operatorIndex: 0)
        let quad = region.quadFromBaseline
        let height = hypot(quad[3].x - quad[0].x, quad[3].y - quad[0].y)
        return PDF.TextRun(
            codes: [], codeCount: text.count, text: text, decoding: .ocr, ownText: nil,
            pdfKitText: nil, origin: quad[0], rotationDeg: region.angleDegrees, height: height,
            width: region.length, quad: quad, fontName: "", fontSubtype: "", isInvisible: false,
            layer: region.paths.first.flatMap { paths[$0].layer },
            source: first, parts: Array(sources.dropFirst()), confidence: confidence,
            shapes: region.shapes)
    }
}
