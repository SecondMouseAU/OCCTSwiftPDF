// CircleFit.swift
// OCCTSwiftPDF
//
// A least-squares circle through points: an algebraic start (Kasa) refined by Gauss-Newton on the
// geometric distance, so the radius is the one that minimises the distance of the points from the
// circle, not a biased one.

import Foundation

/// A circle in the plane.
struct Circle: Equatable, Sendable {
    var centre: SIMD2<Double>
    var radius: Double

    /// The distance of `point` from the circle itself (not from its centre), positive outside.
    func deviation(of point: SIMD2<Double>) -> Double {
        let d = point - centre
        return (d.x * d.x + d.y * d.y).squareRoot() - radius
    }

    /// The circle that minimises the summed squared distance of `points` from it, or `nil` when
    /// there are fewer than three points, they are (nearly) collinear, or the fit is not a finite circle.
    static func fitting(_ points: [SIMD2<Double>]) -> Circle? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        var mean = SIMD2<Double>(0, 0)
        for p in points { mean += p }
        mean /= n
        // Kasa: x^2 + y^2 + D x + E y + F = 0, solved on points moved to their centroid.
        var suu = 0.0
        var svv = 0.0
        var suv = 0.0
        var suuu = 0.0
        var svvv = 0.0
        var suvv = 0.0
        var svuu = 0.0
        for p in points {
            let u = p.x - mean.x
            let v = p.y - mean.y
            suu += u * u
            svv += v * v
            suv += u * v
            suuu += u * u * u
            svvv += v * v * v
            suvv += u * v * v
            svuu += v * u * u
        }
        let det = suu * svv - suv * suv
        // Collinear points have no circle: the determinant is tiny beside the spread.
        guard det.isFinite, abs(det) > 1e-12 * max(suu * suu, svv * svv, 1e-300) else { return nil }
        let rhsU = 0.5 * (suuu + suvv)
        let rhsV = 0.5 * (svvv + svuu)
        let uc = (rhsU * svv - rhsV * suv) / det
        let vc = (suu * rhsV - suv * rhsU) / det
        var a = uc
        var b = vc
        var r = (uc * uc + vc * vc + (suu + svv) / n).squareRoot()
        guard r.isFinite, r > 0 else { return nil }

        // Gauss-Newton on r_i = |p_i - c| - r, in coordinates moved to the centroid.
        for _ in 0..<30 {
            var jtj = [Double](repeating: 0, count: 9)
            var jtr = [Double](repeating: 0, count: 3)
            for p in points {
                let dx = p.x - mean.x - a
                let dy = p.y - mean.y - b
                let d = (dx * dx + dy * dy).squareRoot()
                guard d > 1e-300 else { continue }
                let row = [-dx / d, -dy / d, -1.0]
                let residual = d - r
                for i in 0..<3 {
                    jtr[i] += row[i] * residual
                    for j in 0..<3 { jtj[i * 3 + j] += row[i] * row[j] }
                }
            }
            guard let step = solve3(jtj, jtr) else { break }
            a -= step[0]
            b -= step[1]
            r -= step[2]
            if step.allSatisfy({ abs($0) < 1e-12 * max(1, r) }) { break }
        }
        guard r.isFinite, r > 0, a.isFinite, b.isFinite else { return nil }
        return Circle(centre: SIMD2(mean.x + a, mean.y + b), radius: r)
    }

    /// Solves the 3 by 3 system `m x = rhs` by elimination with partial pivoting.
    private static func solve3(_ m: [Double], _ rhs: [Double]) -> [Double]? {
        var a = m
        var b = rhs
        for column in 0..<3 {
            var pivot = column
            for row in (column + 1)..<3 where abs(a[row * 3 + column]) > abs(a[pivot * 3 + column])
            {
                pivot = row
            }
            guard abs(a[pivot * 3 + column]) > 1e-300 else { return nil }
            if pivot != column {
                for k in 0..<3 { a.swapAt(column * 3 + k, pivot * 3 + k) }
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<3 {
                let factor = a[row * 3 + column] / a[column * 3 + column]
                for k in column..<3 { a[row * 3 + k] -= factor * a[column * 3 + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [0.0, 0.0, 0.0]
        for row in stride(from: 2, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<3 { sum -= a[row * 3 + k] * x[k] }
            x[row] = sum / a[row * 3 + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}
