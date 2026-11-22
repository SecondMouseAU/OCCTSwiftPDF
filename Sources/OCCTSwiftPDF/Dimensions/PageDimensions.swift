// PageDimensions.swift
// OCCTSwiftPDF
//
// Rebuilds a page's dimensions from its loose pieces, and finds the scale from the values against
// the drawn lengths. The rebuild itself is SwiftDXF's (`DXF.Drawing.rebuildingDimensions(_:)`,
// shared with Jw_cad exports); this adds what a PDF page needs: arrowheads that are filled paths,
// one layer for the scale however many layers the file has, a range of credible scales, and views,
// since a PDF has no layer groups to say where a scale might change.

import CoreGraphics
import Foundation
import SwiftDXF

extension PDF.Page {
    /// Rebuilds the page's dimensions from its pieces, without any flag in the file that says which
    /// belong together, and infers the scale from the values against the drawn lengths.
    ///
    /// For each text that states a number it finds the dimension line beside it, the ends that
    /// line spans (where an extension line meets it, or an arrowhead is, if nothing else ends it:
    /// a filled triangle drawn with no stroke counts) and the diameter or radius of a circle, and
    /// takes the scale that explains most of the values; see SwiftDXF's `rebuildingDimensions(_:)`,
    /// which does that. Every pair of pieces is looked at on the whole sheet, whatever layers the
    /// file puts them on, and the scale is found for the sheet.
    ///
    /// A PDF has no layer groups to say where a scale might change, so the page is also split into
    /// views, pieces that lie together apart from the others (`DimensionOptions.viewGap`), and each
    /// is asked for a scale of its own. The dimensions are at the sheet's scale, and a view whose
    /// own values favour another, with at least six values and four fifths of those that vote, has
    /// it as an `alternative` and a `scalesDisagree` warning. It is not applied: on the TECS sheets
    /// such views were nearly always wrong, since few values agree on a scale by chance. Views
    /// that disagree are each kept, never averaged.
    ///
    /// It is an inference and conservative: a value no dimension explains is a warning, never
    /// guessed; a scale outside `DimensionOptions.scaleRange` is not used; and nothing is scaled.
    /// The page's `drawing()` is not changed.
    public func recoveringDimensions(_ options: PDF.DimensionOptions = .init())
        -> PDF.DimensionRecovery
    {
        PDF.DimensionRecoverer(self, options).run()
    }
}

extension PDF {
    /// How strong a view's own scale must be to be reported against the sheet's.
    enum ViewEvidence {
        /// Explained by at least this many of the view's value texts.
        static let minimumSupporting = 6
        /// And by at least this fraction of those of the view that could vote.
        static let minimumShare = 0.8

        static func isStrong(_ scale: DXF.DimensionRebuild.ScaleEstimate) -> Bool {
            let voters = scale.supporting + scale.contradicting
            return scale.supporting >= minimumSupporting
                && Double(scale.supporting) >= minimumShare * Double(voters)
        }
    }

    struct DimensionRecoverer {
        let page: Page
        let options: DimensionOptions

        init(_ page: Page, _ options: DimensionOptions) {
            self.page = page
            self.options = options
        }

        func run() -> DimensionRecovery {
            let working = page.workingDrawing(arrowheads: options.arrowheads)
            let rebuildOptions = DXF.DimensionRebuild.Options(
                scale: options.scale, tolerance: options.tolerance, pieceLayers: .sameAsText,
                numbers: options.numbers)

            // The value texts by identity, and the views.
            var textAt: [DXF.Identity: Int] = [:]
            var heights: [Double] = []
            for (index, entity) in working.entities.enumerated() {
                if case .text(_, let height, _, _, _, _) = entity, height > 0 {
                    textAt[working.identity(ofEntityAt: index)] = index
                    heights.append(height)
                }
            }
            heights.sort()
            let median = heights.isEmpty ? 1 : heights[heights.count / 2]
            let cell = options.viewGap.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? 2 * median
            let views = Views(working, cell: cell)
            func view(of identity: DXF.Identity) -> Int? {
                textAt[identity].map { views.of[$0] }
            }
            func view(of dimension: DXF.Dimension) -> Int? {
                dimension.rebuilt?.pieces.first.flatMap { view(of: $0) }
            }

            // The sheet as one view: the scale and the dimensions.
            var sheet = Self.relayered(working, to: { _ in "sheet" })
                .rebuildingDimensions(rebuildOptions)
            var estimate = sheet.scales.first
            if let found = estimate, options.scale == nil, !options.scaleRange.contains(found.scale)
            {
                // A scale no sheet of paper is credibly at: what it explained is not a dimension.
                estimate = nil
                sheet = Self.withoutScale(sheet)
            }

            // Each view asked for a scale of its own, to say where it disagrees.
            var own: DXF.DimensionRebuild?
            if options.separateViews, options.scale == nil, views.count > 1 {
                own = Self.relayered(working, to: { "view \(views.of[$0] + 1)" })
                    .rebuildingDimensions(rebuildOptions)
            }

            var out: [DimensionView] = []
            var disagreeing: [DXF.DimensionRebuild.ScaleEstimate] = []
            for v in 0..<views.count {
                let dimensions = sheet.dimensions.filter { view(of: $0) == v }.map {
                    Self.restoringLayer($0, from: working, textAt)
                }
                let warnings = sheet.warnings.filter {
                    Self.identity(of: $0).flatMap { view(of: $0) } == v
                }
                guard !dimensions.isEmpty || !warnings.isEmpty else { continue }
                let contradicting = warnings.filter {
                    if case .valueNotExplained(_, _, .noMatch) = $0 { return true }
                    return false
                }.count
                var alternative: DimensionAlternative?
                let name = "view \(v + 1)"
                if let found = own?.scales.first(where: { $0.group == name }),
                    ViewEvidence.isStrong(found), options.scaleRange.contains(found.scale),
                    estimate.map({ abs(found.scale / $0.scale - 1) > 0.01 }) ?? true
                {
                    let instead = (own?.dimensions ?? []).filter { view(of: $0) == v }.map {
                        Self.restoringLayer($0, from: working, textAt)
                    }
                    alternative = DimensionAlternative(scale: found, dimensions: instead)
                    disagreeing.append(
                        DXF.DimensionRebuild.ScaleEstimate(
                            group: name, scale: found.scale, supporting: found.supporting,
                            contradicting: found.contradicting))
                }
                let box = views.bounds[v]
                out.append(
                    DimensionView(
                        number: v + 1,
                        bounds: CGRect(
                            x: box.min.x, y: box.min.y, width: box.width, height: box.height),
                        scale: estimate?.scale, supporting: dimensions.count,
                        contradicting: contradicting, dimensions: dimensions, warnings: warnings,
                        alternative: alternative))
            }
            var all = out.flatMap(\.warnings)
            if !disagreeing.isEmpty {
                all.append(.scalesDisagree((estimate.map { [$0] } ?? []) + disagreeing))
            }
            return DimensionRecovery(sheet: estimate, views: out, warnings: all)
        }

        /// The identity of the value text a warning is about.
        static func identity(of warning: DXF.DimensionRebuild.Warning) -> DXF.Identity? {
            switch warning {
            case .valueNotExplained(_, let identity, _), .symbolDisagrees(_, let identity, _):
                return identity
            case .scalesDisagree:
                return nil
            }
        }

        /// A rebuild whose scale is not believed: its dimensions are none, and each value it
        /// explained is one that nothing explains.
        static func withoutScale(_ rebuild: DXF.DimensionRebuild) -> DXF.DimensionRebuild {
            var warnings = rebuild.warnings
            for dimension in rebuild.dimensions {
                if let text = dimension.textOverride, let id = dimension.rebuilt?.pieces.first {
                    warnings.append(.valueNotExplained(text: text, identity: id, reason: .noScale))
                }
            }
            // The symbol warnings were about dimensions that are no longer there.
            warnings.removeAll {
                if case .symbolDisagrees = $0 { return true }
                return false
            }
            return DXF.DimensionRebuild(dimensions: [], scales: [], warnings: warnings)
        }

        /// `dimension` on the layer its value text is on in the page, not the view it was found in.
        static func restoringLayer(
            _ dimension: DXF.Dimension, from drawing: DXF.Drawing, _ textAt: [DXF.Identity: Int]
        ) -> DXF.Dimension {
            var restored = dimension
            if let id = dimension.rebuilt?.pieces.first, let index = textAt[id],
                case .text(_, _, _, _, let layer, _) = drawing.entities[index]
            {
                restored.layer = layer
            }
            return restored
        }

        /// `drawing` with each entity on the layer `layer` gives for its index: the pieces of a
        /// dimension are looked for on the layer of its text, and the scale is found per layer.
        static func relayered(_ drawing: DXF.Drawing, to layer: (Int) -> String) -> DXF.Drawing {
            var out = drawing
            var entities = drawing.entities
            for (index, entity) in drawing.entities.enumerated() {
                let name = layer(index)
                switch entity {
                case .line(let a, let b, _, let color):
                    entities[index] = .line(a: a, b: b, layer: name, color: color)
                case .point(let at, _, let color):
                    entities[index] = .point(at: at, layer: name, color: color)
                case .polyline(let vertices, let closed, _, let color):
                    entities[index] = .polyline(
                        vertices: vertices, closed: closed, layer: name, color: color)
                case .spline(var spline):
                    spline.layer = name
                    entities[index] = .spline(spline)
                case .text(let at, let height, let rotation, let string, _, let color):
                    entities[index] = .text(
                        at: at, height: height, rotationDeg: rotation, string: string, layer: name,
                        color: color)
                default:
                    break
                }
            }
            // Setting `entities` clears the parallel arrays, which still line up.
            out.entities = entities
            out.identities = drawing.identities
            out.entityLineTypes = drawing.entityLineTypes
            out.textContents = drawing.textContents
            return out
        }
    }
}
