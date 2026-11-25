// PlacementCache.swift
// pdfprobe
//
// The reference placements `arc-pairs` and `arc-misses` keep between runs.

#if os(macOS)
    import Foundation
    import OCCTSwiftPDF
    import SwiftDXF

    /// The reference placements `PDFPROBE_PLACEMENTS` keeps between runs, one line a pair:
    /// `<key><tab>scale<tab>rotation<tab>x<tab>y`.
    ///
    /// A placement depends on the two files and on the layers left out, not on the options under
    /// test, so it is kept under all of them. Placing a reference takes minutes over a folder.
    struct PlacementCache {
        var placements: [String: PDF.Placement] = [:]
        let path: String?

        init() {
            path = ProcessInfo.processInfo.environment["PDFPROBE_PLACEMENTS"]
            guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return
            }
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

        /// The key of the pair of files `file` in `folder` and `paired`, with `excluded` left out.
        static func key(folder: URL, file: String, paired: URL, excluded: Set<String>) -> String {
            let sizes = [folder.appendingPathComponent(file), paired].map {
                ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int) ?? 0
            }
            return "\(folder.path)/\(file)|\(sizes[0])|\(sizes[1])|"
                + excluded.sorted().joined(separator: ",")
        }

        /// The kept placement, or the one `compare` makes (and keeps) for the page and reference.
        mutating func placement(
            _ key: String, page: PDF.Page, reference: DXF.Drawing
        ) -> PDF.Placement? {
            if let kept = placements[key] { return kept }
            // Placed by the default drawing, as `pairs` does, so the placement does not depend on
            // the options being tried.
            guard let made = PDF.compare(page.drawing(), with: reference) else { return nil }
            placements[key] = made.placement
            return made.placement
        }

        func save() {
            guard let path else { return }
            let text = placements.sorted { $0.key < $1.key }.map {
                "\($0.key)\t\($0.value.scale)\t\($0.value.rotationDeg)"
                    + "\t\($0.value.translationX)\t\($0.value.translationY)"
            }.joined(separator: "\n")
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#endif
