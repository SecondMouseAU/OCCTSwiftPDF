import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Dimensions and scales rebuilt from real drawings in the corpus, which is not in the repository.
///
/// The expected values are the ones SwiftJWW recovers from the JWW of the same drawing with Jw_cad's
/// attribute flags (`JWW.Drawing.recoveringDimensions()`), and the scale is the one the JWW's layer
/// group states. Each test is skipped where its files are absent, as in CI.
@Suite("Dimension corpus")
struct DimensionCorpusTests {
    static func page(_ path: String) throws -> PDF.Page {
        let document = try PDF.read(contentsOf: CorpusTests.file(path), maximumPages: 1)
        return try #require(document.pages.first)
    }

    /// The 29 dimension value texts SwiftJWW recovers from the JWW of the 2120 (the 133 and the 559
    /// occur twice).
    static let the2120Values = [
        "1,067", "1,219", "1,245", "1,257", "1,582", "1,829", "1,956", "1,981", "10,439", "133",
        "133", "2,057", "2,105", "2,210", "2,388", "2,438", "2,794", "200", "3,810", "394", "559",
        "559", "629", "800", "864", "9,525", "907", "914", "991",
    ]

    @Test(
        "the 2120 gives the 29 dimensions its JWW gives, at 1:80, with all 29 values supporting it",
        .enabled(if: CorpusTests.exists("tecs-pairs/2120.pdf")))
    func the2120() throws {
        let recovery = try Self.page("tecs-pairs/2120.pdf").recoveringDimensions()
        #expect(
            recovery.dimensions.compactMap(\.textOverride).sorted() == Self.the2120Values.sorted())
        let scale = try #require(recovery.scale)
        #expect(abs(scale - 80) < 1e-9)
        #expect(recovery.warnings.isEmpty)
        for view in recovery.views {
            #expect(view.supporting == view.dimensions.count)
            #expect(view.contradicting == 0)
        }
        #expect(recovery.views.reduce(0) { $0 + $1.supporting } == 29)
        for dimension in recovery.dimensions {
            // Marked as rebuilt and not stored, at the scale it was explained at.
            #expect(dimension.rebuilt?.scale == 80)
        }
    }

    @Test(
        "a sheet with two scale groups in its JWW gives its main scale, and the dimensions its flags give",
        .enabled(if: CorpusTests.exists("tecs-pairs/h15a.pdf")))
    func h15a() throws {
        let recovery = try Self.page("tecs-pairs/h15a.pdf").recoveringDimensions()
        #expect(
            recovery.dimensions.compactMap(\.textOverride).sorted()
                == ["1,067", "1,067", "1,650", "1,650", "1,700", "2,400", "2,400", "5,000"])
        #expect(abs((recovery.scale ?? 0) - 50) < 1e-9)
    }

    @Test(
        "the scales of Jw_cad sheets drawn at 1:100, 1:80 and 1:5 are found",
        .enabled(if: CorpusTests.exists("tecs-pairs/ec01.pdf")))
    func scales() throws {
        let expected: [(String, Double)] = [
            ("ec01", 100), ("dd11a", 80), ("tr30000s", 80), ("jis_mbolt", 5),
        ]
        for (stem, scale) in expected {
            try #require(CorpusTests.exists("tecs-pairs/\(stem).pdf"), "\(stem) is in the corpus")
            let recovery = try Self.page("tecs-pairs/\(stem).pdf").recoveringDimensions()
            let found = try #require(recovery.scale, "\(stem)")
            #expect(abs(found / scale - 1) < 0.005, "\(stem): \(found)")
            #expect(!recovery.dimensions.isEmpty, "\(stem)")
        }
    }

    @Test(
        "a sheet that draws text as shapes has no values to rebuild from, and says nothing",
        .enabled(if: CorpusTests.exists("PDFs/Repw604s.pdf")))
    func noText() throws {
        let recovery = try Self.page("PDFs/Repw604s.pdf").recoveringDimensions()
        #expect(recovery.dimensions.isEmpty)
        #expect(recovery.warnings.isEmpty)
        #expect(recovery.scale == nil)
    }
}
