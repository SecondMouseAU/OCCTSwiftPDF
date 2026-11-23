// Page+ArcEntities.swift
// OCCTSwiftPDF
//
// A recovered circle or arc as the drawing's entity, and as the fit that reports it.

import Foundation
import SwiftDXF

extension PDF.Page {
    /// The circle or arc entity for a recovered run: a DXF arc sweeps counterclockwise, so a run
    /// drawn clockwise has its ends swapped.
    static func entity(for arc: RecoveredArc, layer: String, colour: Int) -> DXF.Entity {
        let centre = DXF.Point(arc.circle.centre.x, arc.circle.centre.y)
        if arc.isCircle {
            return .circle(center: centre, radius: arc.circle.radius, layer: layer, color: colour)
        }
        let counterclockwise = arc.sweep >= 0
        return .arc(
            center: centre, radius: arc.circle.radius,
            startDeg: counterclockwise ? arc.firstDeg : arc.lastDeg,
            endDeg: counterclockwise ? arc.lastDeg : arc.firstDeg, layer: layer, color: colour)
    }

    static func fit(of placed: ArcPlan.Placed, entityIndex: Int) -> PDF.ArcFit {
        let arc = placed.arc
        let counterclockwise = arc.sweep >= 0
        return PDF.ArcFit(
            entityIndex: entityIndex, shape: arc.isCircle ? .circle : .arc,
            input: arc.curves == 0 ? .lines : (arc.lines == 0 ? .curves : .mixed),
            center: DXF.Point(arc.circle.centre.x, arc.circle.centre.y), radius: arc.circle.radius,
            startDeg: arc.isCircle ? 0 : (counterclockwise ? arc.firstDeg : arc.lastDeg),
            endDeg: arc.isCircle ? 360 : (counterclockwise ? arc.lastDeg : arc.firstDeg),
            maxResidual: arc.maxResidual, rmsResidual: arc.rmsResidual, stepRatio: arc.stepRatio,
            segments: placed.segments, sources: placed.sources, lineWidth: placed.lineWidth)
    }
}
