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
        /// Whether Vision reads text in an image here.
        ///
        /// Asked of the recogniser alone, on text drawn as text, so that a fault in the package's
        /// own path cannot make the tests that exercise it skip.
        ///
        /// It is asked on its own thread and given two minutes, so a Vision that stalls on a
        /// machine without its models (a virtual runner, say) skips these tests and does not hold
        /// the suite.
        static let reads: Bool = {
            final class Answer: @unchecked Sendable { var reads = false }
            let answer = Answer()
            let finished = DispatchSemaphore(value: 0)
            let asking = Thread {
                if let image = ShapeTextFixtures.textImage("SCALE 1:50"),
                    let lines = try? VisionTextRecogniser().lines(in: image)
                {
                    answer.reads = lines.contains { $0.text.contains("SCALE") }
                }
                finished.signal()
            }
            asking.start()
            return finished.wait(timeout: .now() + 120) == .success && answer.reads
        }()
    }

    @Suite("Shape text with Vision", .serialized)
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
            // On the baseline the text was drawn on (y = 300, where `recover` puts it).
            #expect(abs(found.origin.x - ink.minX) < 0.1)
            #expect(abs(found.origin.y - 300) < 0.2)
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
            "the page-level call recovers a page from the file's own page",
            .enabled(if: VisionAvailability.reads, "Vision does not read the fixture here"))
        func pageLevel() throws {
            let text = OutlineText.drawn("R25 THK", at: CGPoint(x: 300, y: 300))
            let document = try ShapeTextFixtures.document(text.content)
            let page = try #require(document.pages.first)
            let recovered = try page.recoveringShapeText(
                from: try ShapeTextFixtures.cgPage(document))
            #expect(recovered.report.accepted == 1)
            #expect(Self.characters(recovered.page.texts.first?.text) == "R25THK")
            // The page it was called on is not changed.
            #expect(page.texts.isEmpty)
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
            // The ticks are a cluster that was looked at (the validator's own rule for a run of
            // strokes is tested without Vision, in `ticks()`).
            #expect(report.regions > 0)
            #expect(report.accepted + report.rejectedCount == report.regions)
            // Whatever Vision makes of ticks, it is not accepted as text over a row of them.
            let accepted = report.decisions.filter { $0.outcome == .accepted }
            #expect(accepted.isEmpty, "accepted \(accepted.map { $0.recognised ?? "" })")
        }
    }
#endif
