# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read first

- `okf/index.md`: the repo's OKF bundle (components, references, experiments, policies). Read the
  page the task needs, when it needs it. `okf/components/index.md` is the long-form description of
  the public surface and each internal stage; `okf/experiments/option-1-spike.md` holds the corpus
  results and the open gaps.
- The cross-repo plan that sequences this work is `okf/plans/drawings-toolbox.md` in the
  `ecosystem` repo (Phase 4, vector PDF).

## What this package is

A reader for **vector PDF drawings** into `DXF.Drawing`, the SwiftDXF model that DXF, DWG and JWW
are read into, so that OCCTSwiftIO's `DrawingLoader` can read a PDF like any other drawing. It is a
spike today (Option 1 of the research: Apple's frameworks only); see
`okf/experiments/option-1-spike.md`.

## Licence rules (these are not optional)

- This package is LGPL-2.1, as OCCTSwiftIO is. Only permissive or LGPL code may be linked: Apple's
  frameworks, MIT, BSD, Apache-2.0, zlib. Today the library links SwiftDXF (MIT) and Apple's
  frameworks, and `pdfprobe` also links SwiftJWW (MIT).
- **Never link or copy Poppler, Xpdf (GPL) or MuPDF (AGPL).** Their command-line tools
  (`pdftotext`, `pdffonts`, `pdftocairo`) may be run during development to check results; nothing
  may depend on them.
- su-pdfimporter (MIT) may be read as a reference design. Credit any code that follows it.
- The PDFs in the corpus are third-party drawings. They stay out of the repository and are read
  from `PDF_CORPUS` (default `~/Projects/OCCTDesignLoop/drawingfiles`); tests that need them skip
  where it is absent.

## Build and test

```bash
swift build
swift test
swift test --skip CorpusTests                 # only the hand-built PDFs, as CI runs them
swift test --filter InterpreterTests          # one suite
swift test --filter TextTests/invisible       # one test: <Suite>/<function name>
swift test list                               # identifiers, to build a --filter from
swift run pdfprobe <file-or-folder>...
xcodebuild build -scheme OCCTSwiftPDF-Package -destination 'generic/platform=tvOS'   # also iOS, visionOS
Scripts/build-without-pdfkit.sh tvOS          # PDFKit rewritten out: catches a use outside a guard
swift-format lint --strict --recursive Sources Tests
swiftlint lint --strict
```

`--filter` matches the Swift function name (`invisible()`), not the `@Test("...")` display string.
Where the corpus is present (it is on the maintainer's machine) the `CorpusTests` run as ordinary
tests and fail like any other; they skip only where their files are absent. `pdfprobe` has more
subcommands (`compare`, `pairs`, `debug-text`, `arcs`, `arc-pairs`, `arc-misses`, `digest`); see the
README.

## Architecture

One library target, `OCCTSwiftPDF`, which `@_exported import`s SwiftDXF so callers get `DXF.Drawing`
without a second import. `pdfprobe` is a separate executable and the only target that links
SwiftJWW. The package builds for the platforms OCCTSwiftIO does (macOS, iOS, visionOS, tvOS). PDFKit
is not used on tvOS (older SDKs lack it, and an app built with a newer one might not launch on a
tvOS without it), so every use of it is behind `#if canImport(PDFKit) && !os(tvOS)`, and on tvOS the
text is the package's own decoding alone. `PDF.readReference` (`Process`, `unzip`) and `pdfprobe`
are macOS only. A new `import PDFKit` or `Process` outside such a guard breaks the build on an SDK
without it; `Scripts/build-without-pdfkit.sh` builds for tvOS with PDFKit rewritten out, which
catches a use outside a guard even on an SDK that has the framework.

The read path is a pipeline, and the stages only make sense together:

1. **`PDF.read(contentsOf:)`** (`PDF+Read.swift`) opens a `CGPDFDocument` (an empty password is
   tried), and for each page runs the stages below, then collects document-level layers (optional
   content groups) and the producer and creator strings.
2. **`PageInterpreter`** (`Interpreter/`) drives `CGPDFScanner` over the content stream.
   CoreGraphics only tokenises operators; this class keeps the graphics-state stack, current path,
   text state, marked content (layers) and Form XObjects itself, and emits `PDF.Path`, `PDF.TextRun`
   and `PDF.Image` values in page coordinates (points, y up). It is single-use and not thread-safe:
   one instance per page.
3. **Fonts** (`Fonts/`) are this package's own decoding, called from the interpreter as text is
   shown: how a font's bytes split into codes, each code's advance, and code to Unicode (ToUnicode,
   Shift-JIS `*-RKSJ-*`, Unicode CMaps, simple encodings with `Differences`). An `Identity` CID font
   with no `ToUnicode` map is read last through its embedded TrueType `cmap` (`FontCharacters.swift`,
   `embeddedFont`); a font that has a map keeps it. Each run records how it was decoded
   (`TextDecoding`), including `asciiGuess` where a symbolic or embedded font gave nothing better.
4. **`TextPairing`** asks PDFKit (where it exists) for the characters inside each run's box, as a
   cross-check on the package's own decoding and as a fallback where it has none. PDFKit's
   characters replace only guesses and U+FFFD, and for an inclined run they never replace a reading,
   only fill a gap.
5. **`TextAssembly`** joins runs that continue one another along a baseline, because some writers
   (Jw_cad) show one character per `Tj`.

`PDF.Page.drawing()` (`Page+Drawing.swift`) is the only place that converts to the output model.
`toPaper` is the one coordinate transform (crop box to origin, the page's `/Rotate`, points to
millimetres); text rotation is corrected for the page rotation there as well. Stroked paths become
lines, polylines and one degree-3 spline per Bezier curve. `fittedDrawing()` is the same walk with
the circles and arcs of `Arcs/` put in place of the curves and short lines they replace, planned
first (`Page+ArcPlan.swift`, across subpaths and strokes) and tagged `FITTED`; `drawing()` never
fits. Filled-only paths, images, text with no characters and a frame drawn
on the page edge are not drawn but counted in `skipped` by layer. Every entity gets a
`DXF.Identity` whose locator is `p<page>:op<operatorIndex>[:<piece>]` and whose `via` lists the
Form XObjects it came through.

The comparison code (`Comparison*.swift`, `Similarity.swift`, `SegmentIndex.swift`,
`Reference.swift`, `Arcs/ArcComparison.swift`, `Arcs/ArcMisses.swift`, `Arcs/PieceEnds.swift`) is
spike tooling, not part of the reader. It reads the DXF (or a zip holding one,
through `/usr/bin/unzip`) of the same drawing, fits a similarity transform from the texts that occur
once in each drawing (robust, with a fixed-seed sampler so results repeat, then refined on the
geometry), and reports how much of each drawing lies within a tolerance of the other;
`PDF.compareArcs` then matches the circles and arcs of a `fittedDrawing()` with the reference's,
and `PDF.missedArcs` says what the page draws where it found none.
`pdfprobe` and the corpus tests are its callers.

## Testing notes

- `Tests/.../MiniPDF.swift` writes a PDF by hand from a content stream, resources and extra objects,
  so a test controls every operator. Use it for new interpreter and text tests rather than a corpus
  file.
- The test target builds for macOS only: the corpus tests call the macOS-only
  `PDF.readReference`, and `TextTests` uses PDFKit directly. CI builds the library for the
  other platforms; it does not run tests there.
- `CorpusTests` read real drawings from `PDF_CORPUS` and gate each test with
  `.enabled(if: CorpusTests.exists(...))`. One test also reads a DXF kept outside the corpus
  (`~/Documents/Modelling/2DFiles/2120_from_2120j.dxf`).
- Do not pair PDFKit text by `characterBounds(at:)`: it indexes PDFKit's own character list, not
  `PDFPage.string`, so it returns neighbouring characters. `TextPairing` goes through
  `selection(for:)` instead.

## Conventions

- Swift 6 language mode. Swift Testing (`@Suite` / `@Test` / `#expect`). Never
  `#expect(x != nil); #expect(x!.y)`: use `if let x { #expect(x.y) }`.
- swift-format `--strict`: a doc comment's summary line ends with a period and is followed by a
  blank `///` line. CI lints `Sources` and `Tests` with it; SwiftLint runs only
  `orphaned_doc_comment` and excludes `Tests`. `Scripts/comment-ratio-check.sh` only reports.
- New code is one type, or one tight family, per file (`okf/policies/code-structure.md`).
- No em-dashes and no "honest" or "you're right" in prose (`okf/policies/writing-style.md`).
- Docs ship with the change (`okf/policies/docs-current.md`): a change to the public surface also
  updates `okf/components/index.md` and the README, and a change to what the reader achieves
  updates the experiment page.
- Analytic, not pixels: correctness is shown against the paired DXF or JWW of the same drawing,
  by coordinates, never by comparing pictures.
- CI runs on GitHub's hosted `macos-15` runners, which are free for this public repo. `tests.yml`
  also builds the package for iOS, tvOS and visionOS.
