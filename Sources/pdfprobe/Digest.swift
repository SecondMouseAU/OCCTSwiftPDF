// Digest.swift
// pdfprobe
//
// `pdfprobe digest`: a hash of what `drawing()` makes of each PDF, to show that a change to the
// reader left the default drawing alone.

#if os(macOS)
    import Foundation
    import OCCTSwiftPDF
    import SwiftDXF

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
#endif
