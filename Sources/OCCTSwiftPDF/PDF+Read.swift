// PDF+Read.swift
// OCCTSwiftPDF
//
// Reading a PDF document: each page through the interpreter, then each text run paired with the
// characters PDFKit finds in its box (TextPairing.swift, where PDFKit exists), then runs joined
// into lines.

import CoreGraphics
import Foundation

#if canImport(PDFKit)
    import PDFKit
#endif

extension PDF {
    public enum Error: Swift.Error, Equatable {
        /// The file is not a PDF CoreGraphics can open, or it is encrypted with a password.
        case cannotOpen
    }

    /// Read every page of the PDF at `url`, or the first `maximumPages`.
    ///
    /// A file encrypted with an empty user password (only its permissions restricted) is opened.
    /// Where PDFKit exists each text run is also checked against it; on tvOS, which has none, a run
    /// keeps the text this reader's own font decoding gave it.
    public static func read(contentsOf url: URL, maximumPages: Int? = nil) throws -> Document {
        try read(contentsOf: url, maximumPages: maximumPages, crossCheck: true)
    }

    /// As ``read(contentsOf:maximumPages:)``, with `crossCheck: false` leaving PDFKit out of the
    /// text, as on tvOS, so that path is also exercised where PDFKit is present.
    static func read(contentsOf url: URL, maximumPages: Int?, crossCheck: Bool) throws -> Document {
        guard let document = CGPDFDocument(url as CFURL) else { throw Error.cannotOpen }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw Error.cannotOpen
        }
        #if canImport(PDFKit)
            let kit = crossCheck ? PDFDocument(url: url) : nil
            if let kit, kit.isLocked { _ = kit.unlock(withPassword: "") }
        #endif
        let count = min(document.numberOfPages, maximumPages ?? .max)
        var pages: [Page] = []
        for number in 1...max(count, 1) where number <= count {
            guard let page = document.page(at: number) else { continue }
            var read = Self.read(page, number: number)
            #if canImport(PDFKit)
                if let kitPage = kit?.page(at: number - 1) {
                    TextPairing.pair(&read.texts, with: kitPage)
                }
            #endif
            read.texts = TextAssembly.lines(read.texts)
            pages.append(read)
        }
        return Document(
            url: url, pageCount: document.numberOfPages, pages: pages,
            layers: declaredLayers(document), layersOff: layersOff(document),
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

    /// The names of the layers the default configuration (`/D`) lists in `/OFF`.
    static func layersOff(_ document: CGPDFDocument) -> [String] {
        guard let catalog = document.catalog,
            let properties = PDFObjects.dictionary(catalog, "OCProperties"),
            let configuration = PDFObjects.dictionary(properties, "D"),
            let off = PDFObjects.array(configuration, "OFF")
        else { return [] }
        return (0..<CGPDFArrayGetCount(off)).compactMap { index in
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(off, index, &group), let group else { return nil }
            return PDFObjects.text(group, "Name")
        }
    }

    static func info(_ document: CGPDFDocument, _ key: String) -> String? {
        guard let info = document.info else { return nil }
        return PDFObjects.text(info, key)
    }
}
