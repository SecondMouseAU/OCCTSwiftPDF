// Similarity.swift
// OCCTSwiftPDF
//
// Spike tooling: a 2D similarity transform, fitted by least squares or robustly.

import Foundation
import SwiftDXF

extension PDF {
    /// A 2D similarity transform: scale, rotation and translation.
    struct Similarity: Sendable {
        var scale: Double
        var rotation: Double
        var tx: Double
        var ty: Double

        func apply(_ p: DXF.Point2) -> DXF.Point2 {
            let c = cos(rotation) * scale
            let s = sin(rotation) * scale
            return DXF.Point2(c * p.x - s * p.y + tx, s * p.x + c * p.y + ty)
        }

        /// The similarity, fitted to two of `pairs`, that takes the most of them within `within`
        /// of their targets: every pair of anchors is tried when there are up to 80, otherwise
        /// 3,000 pairs drawn by a fixed-seed generator, so a comparison gives the same result each
        /// time it is run.
        static func robustFit(_ pairs: [(from: DXF.Point2, to: DXF.Point2)], within: Double)
            -> Similarity?
        {
            var candidates: [(Int, Int)] = []
            if pairs.count <= 80 {
                for i in pairs.indices {
                    for j in pairs.indices where j > i { candidates.append((i, j)) }
                }
            } else {
                var generator = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
                for _ in 0..<3_000 {
                    let i = Int.random(in: 0..<pairs.count, using: &generator)
                    let j = Int.random(in: 0..<pairs.count, using: &generator)
                    if i != j { candidates.append((i, j)) }
                }
            }
            var best: (fit: Similarity, inliers: Int)?
            for (i, j) in candidates {
                guard pairs[i].from.distance(to: pairs[j].from) > 1e-9,
                    let fit = Similarity.fit([pairs[i], pairs[j]]), fit.scale > 0
                else { continue }
                let inliers = pairs.filter { fit.apply($0.from).distance(to: $0.to) <= within }
                    .count
                if inliers > (best?.inliers ?? 1) { best = (fit, inliers) }
            }
            return best?.fit
        }

        /// The least-squares similarity taking each `from` to its `to` (Umeyama, in 2D).
        static func fit(_ pairs: [(from: DXF.Point2, to: DXF.Point2)]) -> Similarity? {
            let n = Double(pairs.count)
            let fx = pairs.map(\.from.x).reduce(0, +) / n
            let fy = pairs.map(\.from.y).reduce(0, +) / n
            let tx = pairs.map(\.to.x).reduce(0, +) / n
            let ty = pairs.map(\.to.y).reduce(0, +) / n
            var sxx = 0.0
            var sxy = 0.0
            var spread = 0.0
            for (from, to) in pairs {
                let ax = from.x - fx
                let ay = from.y - fy
                let bx = to.x - tx
                let by = to.y - ty
                sxx += ax * bx + ay * by
                sxy += ax * by - ay * bx
                spread += ax * ax + ay * ay
            }
            guard spread > 1e-12 else { return nil }
            let rotation = atan2(sxy, sxx)
            let scale = hypot(sxx, sxy) / spread
            let c = cos(rotation) * scale
            let s = sin(rotation) * scale
            return Similarity(
                scale: scale, rotation: rotation, tx: tx - (c * fx - s * fy),
                ty: ty - (s * fx + c * fy))
        }
    }

    /// A small deterministic random number generator (SplitMix64).
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
