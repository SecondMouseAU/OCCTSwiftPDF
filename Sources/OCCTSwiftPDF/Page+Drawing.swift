// Page+Drawing.swift
// OCCTSwiftPDF
//
// A page as a DXF.Drawing: upright, in millimetres on the paper, one entity per stroked piece and
// text run, each with an identity that names where it came from.

import CoreGraphics
import Foundation
import SwiftDXF

extension PDF.Page {
    /// The transform from page coordinates to millimetres on the upright sheet, with the crop
    /// box's lower left corner at the origin and the page's `/Rotate` applied.
    public var toPaper: CGAffineTransform {
        let box = cropBox
        let millimetres = 25.4 / 72
        let w = box.width
        let h = box.height
        // Upright coordinates for a page shown turned clockwise by `rotation`.
        let upright: CGAffineTransform
        switch rotation {
        case 90: upright = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: upright = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: upright = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: upright = .identity
        }
        return CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(upright)
            .concatenating(CGAffineTransform(scaleX: millimetres, y: millimetres))
    }

    /// The page as a drawing in millimetres on the paper.
    ///
    /// Stroked paths become lines, polylines (runs of straight segments) and degree-3 splines
    /// (one per Bezier curve), so SwiftDXF's `Entity.fitted(tolerance:)` can turn curves into arcs.
    /// Text runs with characters become text, including invisible ones (render mode 3): a writer
    /// that draws text as shapes often lays the same text invisibly over them, so it can be
    /// searched, and that is then the only text there is. Filled-only paths, images and text with
    /// no characters are counted in `skipped` by layer, not drawn.
    public func drawing() -> DXF.Drawing {
        let transform = toPaper
        var entities: [DXF.Entity] = []
        var identities: [DXF.Identity] = []
        var counts = DXF.Drawing.Counts()
        var skipped: [String: Int] = [:]
        var skippedByLayer: [String: [String: Int]] = [:]
        var layerNames: [String] = ["0"]

        func layerName(_ layer: String?) -> String {
            let name = layer ?? "0"
            if !layerNames.contains(name) { layerNames.append(name) }
            return name
        }
        func skip(_ type: String, _ layer: String) {
            skipped[type, default: 0] += 1
            skippedByLayer[type, default: [:]][layer, default: 0] += 1
        }
        func point(_ p: CGPoint) -> DXF.Point {
            let q = p.applying(transform)
            return DXF.Point(q.x, q.y)
        }
        // One painted path can become several entities, so each gets the path's source and its
        // place among them: `p1:op5:0`, `p1:op5:1`. A text is `p1:op7`.
        func add(_ entity: DXF.Entity, _ source: PDF.Source, piece: Int? = nil) {
            entities.append(entity)
            let locator =
                "p\(source.page):op\(source.operatorIndex)" + (piece.map { ":\($0)" } ?? "")
            identities.append(
                DXF.Identity(
                    locator: locator, via: source.forms,
                    blocks: source.forms.map { String($0.split(separator: "#").first ?? "") }))
        }

        for path in paths {
            let layer = layerName(path.layer)
            guard path.paint != .fill else {
                skip("FILL", layer)
                continue
            }
            let colour = Self.aci(path.strokeColour)
            var piece = 0
            func addPiece(_ entity: DXF.Entity) {
                add(entity, path.source, piece: piece)
                piece += 1
            }
            for subpath in path.subpaths {
                var run: [DXF.Point] = [point(subpath.start)]
                var previous = subpath.start
                func flush(closed: Bool) {
                    if run.count == 2 && !closed {
                        addPiece(.line(a: run[0], b: run[1], layer: layer, color: colour))
                        counts.line += 1
                    } else if run.count >= 2 {
                        let vertices = (closed ? run.dropLast() : run[...]).map {
                            DXF.PolyVertex($0)
                        }
                        addPiece(
                            .polyline(
                                vertices: vertices, closed: closed, layer: layer, color: colour))
                        counts.polyline += 1
                    }
                }
                var hasCurve = false
                for segment in subpath.segments {
                    switch segment {
                    case .line(let to):
                        run.append(point(to))
                    case .curve(let c1, let c2, let to):
                        hasCurve = true
                        flush(closed: false)
                        let spline = DXF.Spline(
                            degree: 3, flags: 8,
                            controlPoints: [point(previous), point(c1), point(c2), point(to)],
                            knots: [0, 0, 0, 0, 1, 1, 1, 1], layer: layer, color: colour)
                        addPiece(.spline(spline))
                        counts.spline += 1
                        run = [point(to)]
                    }
                    previous = segment.end
                }
                flush(closed: subpath.isClosed && !hasCurve && run.count > 3)
            }
        }

        let paperRotation = Double(rotation)
        for text in texts {
            let layer = layerName(text.layer)
            guard let string = text.text, !string.isEmpty else {
                skip("TEXT", layer)
                continue
            }
            add(
                .text(
                    at: point(text.origin), height: text.height * 25.4 / 72,
                    rotationDeg: Self.normalised(text.rotationDeg - paperRotation), string: string,
                    layer: layer, color: 7),
                text.source)
            counts.text += 1
        }
        for _ in images { skip("IMAGE", layerName(nil)) }

        var drawing = DXF.Drawing(
            version: "PDF", entities: entities, counts: counts, insUnits: 4, skipped: skipped,
            skippedByLayer: skippedByLayer,
            layers: layerNames.map {
                DXF.Layer(name: $0, identity: DXF.Identity(locator: "LAYER:\($0)"))
            })
        drawing.identities = identities
        return drawing
    }

    static func normalised(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// The nearest of the eight basic AutoCAD colours: black and white are 7.
    static func aci(_ colour: PDF.Colour) -> Int {
        let palette: [(Int, Double, Double, Double)] = [
            (1, 1, 0, 0), (2, 1, 1, 0), (3, 0, 1, 0), (4, 0, 1, 1), (5, 0, 0, 1), (6, 1, 0, 1),
            (7, 0, 0, 0), (7, 1, 1, 1), (8, 0.5, 0.5, 0.5),
        ]
        return palette.min { a, b in
            distance(colour, a) < distance(colour, b)
        }!.0
    }

    private static func distance(_ c: PDF.Colour, _ p: (Int, Double, Double, Double)) -> Double {
        let dr = c.red - p.1
        let dg = c.green - p.2
        let db = c.blue - p.3
        return dr * dr + dg * dg + db * db
    }
}
