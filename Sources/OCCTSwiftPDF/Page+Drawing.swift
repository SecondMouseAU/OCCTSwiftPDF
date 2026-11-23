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
    /// (one per Bezier curve), so SwiftDXF's `Entity.fitted(tolerance:)` can turn curves into arcs;
    /// ``fittedDrawing(_:)`` recovers whole circles and arcs, with the radius over the whole run.
    /// Text runs with characters become text, including invisible ones (render mode 3): a writer
    /// that draws text as shapes often lays the same text invisibly over them, so it can be
    /// searched, and that is then the only text there is. Filled-only paths, images, text with no
    /// characters and a frame drawn on the page's own edge (`PAGE BORDER`) are counted in
    /// `skipped` by layer, not drawn.
    public func drawing() -> DXF.Drawing {
        build(fitting: nil).drawing
    }

    /// The page as a drawing in millimetres on the paper, with each run of curves, or of short
    /// straight lines, that is really one circle or arc replaced by that circle or arc.
    ///
    /// This is ``drawing()`` with the curves and polylines of a circle recovered. A run is taken
    /// only when one circle, fitted over the whole run, passes within the tolerances of `fitting`
    /// of all of it, and everything else is as ``drawing()`` has it. Each circle or arc has a
    /// ``PDF/ArcFit`` with its radius, centre and residual, tagged `FITTED`, and its identity's
    /// locator ends in `:FITTED`.
    public func fittedDrawing(_ fitting: PDF.ArcFitting = PDF.ArcFitting()) -> PDF.FittedDrawing {
        build(fitting: fitting)
    }

    private func build(fitting: PDF.ArcFitting?) -> PDF.FittedDrawing {
        let transform = toPaper
        // The circles and arcs to put in place of curves and lines, where they were drawn.
        let plan = fitting.map { arcPlan($0) }
        var fits: [PDF.ArcFit] = []
        var emitted = Set<Int32>()
        var curvesReplaced = 0
        var linesReplaced = 0
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
        func add(
            _ entity: DXF.Entity, _ source: PDF.Source, piece: Int? = nil, fitted: Bool = false
        ) {
            entities.append(entity)
            let locator =
                "p\(source.page):op\(source.operatorIndex)" + (piece.map { ":\($0)" } ?? "")
                + (fitted ? ":\(PDF.ArcFit.provenance)" : "")
            identities.append(
                DXF.Identity(
                    locator: locator, via: source.forms,
                    blocks: source.forms.map { String($0.split(separator: "#").first ?? "") }))
        }

        for (pathIndex, path) in paths.enumerated() {
            let layer = layerName(path.layer)
            guard path.paint != .fill else {
                skip("FILL", layer)
                continue
            }
            let colour = Self.aci(path.strokeColour)
            var piece = 0
            func addPiece(_ entity: DXF.Entity, fitted: Bool = false) {
                add(entity, path.source, piece: piece, fitted: fitted)
                piece += 1
            }
            for (subpathIndex, subpath) in path.subpaths.enumerated() {
                if isPageBorder(subpath) {
                    skip("PAGE BORDER", layer)
                    continue
                }
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
                let segments = subpath.segments
                var index = 0
                while index < segments.count {
                    if let plan, case let id = plan.owner[pathIndex][subpathIndex][index], id >= 0 {
                        // A circle or arc takes this segment and those after it that it owns.
                        flush(closed: false)
                        hasCurve = true
                        var end = index
                        while end < segments.count,
                            plan.owner[pathIndex][subpathIndex][end] == id
                        {
                            end += 1
                        }
                        if emitted.insert(id).inserted {
                            let placed = plan.arcs[Int(id)]
                            fits.append(Self.fit(of: placed, entityIndex: entities.count))
                            let entity = Self.entity(for: placed.arc, layer: layer, colour: colour)
                            addPiece(entity, fitted: true)
                            if case .circle = entity { counts.circle += 1 } else { counts.arc += 1 }
                            curvesReplaced += placed.arc.curves
                            linesReplaced += placed.arc.lines
                        }
                        previous = segments[end - 1].end
                        run = [point(previous)]
                        index = end
                        continue
                    }
                    switch segments[index] {
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
                    previous = segments[index].end
                    index += 1
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
        return PDF.FittedDrawing(
            drawing: drawing, fits: fits, curvesReplaced: curvesReplaced,
            linesReplaced: linesReplaced)
    }

    /// A closed run of straight segments whose corners are the page's corners, within one point:
    /// the frame some PDF writers draw round the page (MicroArts JWtoPDF does), which is not part
    /// of the drawing.
    func isPageBorder(_ subpath: PDF.Subpath) -> Bool {
        guard subpath.isClosed, (4...5).contains(subpath.segments.count) else { return false }
        var points = [subpath.start]
        for segment in subpath.segments {
            guard case .line(let to) = segment else { return false }
            points.append(to)
        }
        let box = cropBox
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ]
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
        return corners.allSatisfy { corner in points.contains { near($0, corner) } }
            && points.allSatisfy { point in corners.contains { near($0, point) } }
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
