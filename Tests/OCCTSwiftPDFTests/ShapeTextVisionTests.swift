import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

#if canImport(Vision)

    /// Recognition by Apple Vision, on text this suite draws as shapes itself.
    ///
    /// Vision's output differs by OS version, so a test asserts the agreement rules on hand-built
    /// fixtures (clean Helvetica, so the characters themselves are safe to expect), never exact
    /// strings from the corpus. Where Vision cannot recognise anything on the machine (a headless
    /// or virtual runner without its models, say) these tests are skipped, and the probe test says
    /// so in the log.
    enum VisionAvailability {
        /// Whether Vision reads a clean fixture here: the pipeline's own recogniser on "SCALE 1:50".
        static let reads: Bool = {
            guard
                let document = try? ShapeTextFixtures.document(
                    OutlineText.drawn("SCALE 1:50", at: CGPoint(x: 100, y: 100)).content),
                let recovery = try? document.recoveringShapeText()
            else { return false }
            return recovery.reports[1]?.accepted == 1
        }()
    }

    @Suite("Shape text with Vision")
    struct ShapeTextVisionTests {
        /// What the recogniser made of one string drawn as shapes, and the fixture's ink.
        static func recover(
            _ string: String, rotationDegrees: Double = 0, stroke: Bool = false,
            size: Double = 10
        ) throws -> (run: PDF.TextRun?, report: PDF.ShapeTextReport, ink: CGRect) {
            let text = OutlineText.drawn(
                string, size: size, at: CGPoint(x: 300, y: 300),
                rotationDegrees: rotationDegrees, stroke: stroke)
            let document = try ShapeTextFixtures.document(text.content)
            let recovery = try document.recoveringShapeText()
            let report = try #require(recovery.reports[1])
            return (recovery.document.pages.first?.texts.first, report, text.ink)
        }

        static func characters(_ text: String?) -> String? {
            text?.filter { !$0.isWhitespace }
        }

        @Test("whether Vision reads text on this machine, for the log")
        func probe() {
            print("Vision reads a clean fixture on this machine: \(VisionAvailability.reads)")
        }

        @Test(
            "filled outlines are read, and the text is placed by the shapes",
            .enabled(if: VisionAvailability.reads, "Vision does not read the fixture here"),
            arguments: ["10,439", "SCALE 1:50", "R25 THK", "Hello World"])
        func filled(string: String) throws {
            let (run, report, ink) = try Self.recover(string)
            #expect(report.accepted == 1)
            #expect(report.regions == 1)
            let found = try #require(run)
            #expect(Self.characters(found.text) == Self.characters(string))
            #expect(found.decoding == .ocr)
            if let confidence = found.confidence { #expect(confidence >= 0.5) }
            #expect(abs(found.origin.x - ink.minX) < 0.1)
            #expect(abs(found.origin.y - ink.minY) < 0.1)
        }

        @Test(
            "hollow outlines (strokes) are read",
            .enabled(if: VisionAvailability.reads, "Vision does not read the fixture here"),
            arguments: ["10,439", "R25 THK"])
        func stroked(string: String) throws {
            let (run, report, _) = try Self.recover(string, stroke: true)
            #expect(report.accepted == 1)
            #expect(Self.characters(run?.text) == Self.characters(string))
        }

        @Test(
            "text turned up, down or aslant is read along its own direction",
            .enabled(if: VisionAvailability.reads, "Vision does not read the fixture here"),
            arguments: [90.0, 270.0, 30.0, -20.0])
        func turned(degrees: Double) throws {
            let (run, report, _) = try Self.recover("SECTION", rotationDegrees: degrees)
            #expect(report.accepted == 1, "rejected: \(report.rejected)")
            let found = try #require(run)
            #expect(Self.characters(found.text) == "SECTION")
            let expected = (degrees + 360).truncatingRemainder(dividingBy: 360)
            var error = abs(found.rotationDeg - expected)
            if error > 180 { error = 360 - error }
            #expect(error < 3, "read at \(found.rotationDeg), drawn at \(expected)")
        }

        @Test(
            "small text is rendered large enough to read",
            .enabled(if: VisionAvailability.reads, "Vision does not read the fixture here"))
        func small() throws {
            let (run, report, _) = try Self.recover("0,48", size: 3)
            #expect(report.accepted == 1)
            #expect(Self.characters(run?.text) == "0,48")
        }

        @Test(
            "shapes that are not text give no text",
            .enabled(if: VisionAvailability.reads, "Vision does not read the fixture here"))
        func notText() throws {
            // A row of short ticks, as a scale or a hatch has, and a scribble of curves.
            var content = "0.4 w\n"
            for tick in 0..<12 {
                let x = 100 + 4 * tick
                content += "\(x) 100 m \(x) 106 l S\n"
            }
            content += "200 200 m 210 215 214 190 224 204 c 230 214 236 188 246 200 c S\n"
            let document = try ShapeTextFixtures.document(content)
            let recovery = try document.recoveringShapeText()
            let report = try #require(recovery.reports[1])
            #expect(report.accepted + report.rejectedCount == report.regions)
            // Whatever Vision makes of ticks, it is not accepted as text over a row of them.
            let accepted = report.decisions.filter { $0.outcome == .accepted }
            #expect(accepted.isEmpty, "accepted \(accepted.map { $0.recognised ?? "" })")
        }
    }
#endif
