import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The least-squares circle under the arc recovery.
@Suite("Circle fit")
struct CircleFitTests {
    static func points(
        centre: SIMD2<Double>, radius: Double, from start: Double, sweep: Double, count: Int
    ) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for k in 0..<count {
            let angle = (start + sweep * Double(k) / Double(count - 1)) * .pi / 180
            out.append(SIMD2(centre.x + radius * cos(angle), centre.y + radius * sin(angle)))
        }
        return out
    }

    @Test("points on a circle give that circle back")
    func exact() throws {
        let points = Self.points(
            centre: SIMD2(120, -40), radius: 25.4, from: 10, sweep: 300, count: 40)
        let circle = try #require(Circle.fitting(points))
        #expect(abs(circle.radius - 25.4) < 1e-9)
        #expect(abs(circle.centre.x - 120) < 1e-9 && abs(circle.centre.y + 40) < 1e-9)
    }

    @Test("a short arc far from the origin keeps its radius")
    func shortArc() throws {
        // 40 degrees of a 50 mm circle, 800 mm from the origin: the case a bare algebraic fit
        // gets wrong when the points are not moved to their centroid.
        let points = Self.points(
            centre: SIMD2(800, 600), radius: 50, from: 100, sweep: 40, count: 9)
        let circle = try #require(Circle.fitting(points))
        #expect(abs(circle.radius - 50) < 1e-6)
        #expect(abs(circle.centre.x - 800) < 1e-6 && abs(circle.centre.y - 600) < 1e-6)
    }

    @Test("noise on the points moves the radius by about the noise, not more")
    func noisy() throws {
        var points = Self.points(centre: SIMD2(0, 0), radius: 10, from: 0, sweep: 270, count: 60)
        // Radial noise of up to 0.005, alternating.
        for index in points.indices {
            let sign = index % 2 == 0 ? 1.0 : -1.0
            points[index] += sign * 0.005 * points[index] / 10
        }
        let circle = try #require(Circle.fitting(points))
        #expect(abs(circle.radius - 10) < 0.005)
        for point in points { #expect(abs(circle.deviation(of: point)) <= 0.0051) }
    }

    @Test("collinear points and too few points are not a circle")
    func degenerate() {
        var line: [SIMD2<Double>] = []
        for k in 0..<10 { line.append(SIMD2(Double(k), 2 * Double(k) + 1)) }
        #expect(Circle.fitting(line) == nil)
        #expect(Circle.fitting(Array(line.prefix(2))) == nil)
        #expect(Circle.fitting([]) == nil)
    }

    @Test("the fit is the geometric optimum: the squared distances are at a minimum")
    func geometricOptimum() throws {
        // A 60 degree arc of a 50 mm circle with 0.05 mm of radial noise in a fixed pattern: the
        // algebraic start is biased here, and the refinement is what puts it right.
        var points = Self.points(centre: SIMD2(3, 4), radius: 50, from: 100, sweep: 60, count: 12)
        for index in points.indices {
            let sign = index % 3 == 0 ? 1.0 : -1.0
            let out = (points[index] - SIMD2(3, 4)) / 50
            points[index] += sign * 0.05 * out
        }
        let circle = try #require(Circle.fitting(points))
        // The gradient of the summed squared distances with respect to centre and radius.
        var gradient = SIMD3<Double>(0, 0, 0)
        for point in points {
            let offset = point - circle.centre
            let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            let residual = distance - circle.radius
            gradient.x += residual * (-offset.x / distance)
            gradient.y += residual * (-offset.y / distance)
            gradient.z += -residual
        }
        #expect(abs(gradient.x) < 1e-6 && abs(gradient.y) < 1e-6 && abs(gradient.z) < 1e-6)
    }
}
