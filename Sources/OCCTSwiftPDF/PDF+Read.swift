// PDF+Read.swift
// OCCTSwiftPDF
//
// Reading a PDF document: each page through the interpreter, then each text run paired with the
// characters PDFKit finds in its box.

import CoreGraphics
import Foundation
import PDFKit

extension PDF {
    public enum Error: Swift.Error, Equatable {
        /// The file is not a PDF CoreGraphics can open, or it is encrypted.
        case cannotOpen
    }

    /// Read every page of the PDF at `url`, or the first `maximumPages`.
    public static func read(contentsOf url: URL, maximumPages: Int? = nil) throws -> Document {
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted else {
            throw Error.cannotOpen
        }
        let kit = PDFDocument(url: url)
        let count = min(document.numberOfPages, maximumPages ?? .max)
        var pages: [Page] = []
        for number in 1...max(count, 1) where number <= count {
            guard let page = document.page(at: number) else { continue }
            var read = Self.read(page, number: number)
            if let kitPage = kit?.page(at: number - 1) {
                TextPairing.pair(&read.texts, with: kitPage)
            }
            read.texts = TextAssembly.lines(read.texts)
            pages.append(read)
        }
        return Document(
            url: url, pages: pages, layers: declaredLayers(document),
            producer: info(document, "Producer"), creator: info(document, "Creator"))
    }

    static func read(_ page: CGPDFPage, number: Int) -> Page {
        let interpreter = PageInterpreter(pageNumber: number)
        interpreter.run(page)
        return Page(
            number: number, mediaBox: page.getBoxRect(.mediaBox),
            cropBox: page.getBoxRect(.cropBox),
            rotation: ((Int(page.rotationAngle) % 360) + 360) % 360, paths: interpreter.paths,
            texts: interpreter.texts, images: interpreter.images, clipPaths: interpreter.clipPaths,
            formInvocations: interpreter.formInvocations, inlineImages: interpreter.inlineImages,
            shadings: interpreter.shadings, layers: interpreter.layersSeen)
    }

    /// The names of the optional content groups in the catalog's `OCProperties`.
    static func declaredLayers(_ document: CGPDFDocument) -> [String] {
        guard let catalog = document.catalog,
            let properties = PDFObjects.dictionary(catalog, "OCProperties"),
            let groups = PDFObjects.array(properties, "OCGs")
        else { return [] }
        return (0..<CGPDFArrayGetCount(groups)).compactMap { index in
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(groups, index, &group), let group else { return nil }
            return PDFObjects.text(group, "Name")
        }
    }

    static func info(_ document: CGPDFDocument, _ key: String) -> String? {
        guard let info = document.info else { return nil }
        return PDFObjects.text(info, key)
    }
}

/// Pairs text runs with the characters PDFKit finds in their boxes.
///
/// PDFKit decodes some text this reader cannot (fonts it gives no other way back from codes to
/// characters). Its selections are in the same page coordinates the interpreter uses. A character's
/// box must be asked for through a selection: `characterBounds(at:)` indexes PDFKit's own character
/// list, which is not `PDFPage.string`, since the string has spaces and line breaks added.
enum TextPairing {
    static func pair(_ runs: inout [PDF.TextRun], with page: PDFPage) {
        for index in runs.indices {
            let run = runs[index]
            guard run.width > 0, run.height > 0, let rect = innerRect(run) else { continue }
            let found = page.selection(for: rect)?.string?
                .filter { !$0.isWhitespace && !$0.isNewline }
            guard let found, !found.isEmpty else { continue }
            runs[index].pdfKitText = found
            if run.text == nil {
                runs[index].text = found
                runs[index].decoding = .pdfKit
            }
        }
    }

    /// The axis-aligned box around the run from its baseline to 75 percent of its height, short
    /// of each end by a tenth of its height.
    ///
    /// PDFKit selects a character when the centre of its box is inside the rectangle, and its
    /// boxes run from the font's descender to its ascender, so the centres sit about a quarter of
    /// the size above the baseline. The band takes those and leaves out the lines above and below.
    static func innerRect(_ run: PDF.TextRun) -> CGRect? {
        guard run.quad.count == 4 else { return nil }
        let base = run.quad[0]
        let along = CGPoint(x: run.quad[1].x - base.x, y: run.quad[1].y - base.y)
        let up = CGPoint(x: run.quad[3].x - base.x, y: run.quad[3].y - base.y)
        let length = max(hypot(along.x, along.y), 1e-9)
        let inset = min(run.height * 0.1, length * 0.25) / length
        var points: [CGPoint] = []
        for t in [inset, 1 - inset] {
            for v in [0.0, 0.75] {
                points.append(
                    CGPoint(x: base.x + along.x * t + up.x * v, y: base.y + along.y * t + up.y * v))
            }
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
