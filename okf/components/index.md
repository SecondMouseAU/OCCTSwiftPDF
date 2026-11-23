---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [index]
description: Public modules and API surfaces exposed by OCCTSwiftPDF.
timestamp: 2026-11-23
---

# Components

- **`OCCTSwiftPDF`** (library). It re-exports SwiftDXF, whose `DXF.Drawing` is what a PDF is read
  into.
  - `PDF.read(contentsOf:maximumPages:)` reads a document into `PDF.Document`: per page, painted
    `PDF.Path`s (subpaths of lines and Bezier curves in page coordinates, with paint, line width,
    dash, colours, layer and source), `PDF.TextRun`s (characters, how they were decoded, origin,
    direction, size, width, box, font, visibility, layer, source), placed `PDF.Image`s, and counts
    of clip paths, Form XObjects, inline images and shadings. The document also gives its page
    count, the layers (optional content groups) its catalog declares, and those its default
    configuration turns off. A file encrypted with an empty password is opened.
  - `PDF.Page.kind` says whether a page is `vector`, `raster` (a scanned sheet), `mixed` or
    `empty`, from the fraction of the page images cover (`imageCoverage`) and the number of
    segments drawn.
  - `PDF.Page.drawing()` turns a page into a `DXF.Drawing` in millimetres on the upright sheet:
    lines, polylines and one degree-3 spline per Bezier curve (so SwiftDXF's
    `Entity.fitted(tolerance:)` can fit arcs), and text. Each entity's identity names the page,
    the operator and any Form XObjects it came through, with the piece's place among those one
    painted path became (`p1:op120:0`, via `Fm0#1`). Filled-only paths, images and text with no
    characters are counted in `skipped` by layer.
  - `PDF.Page.recoveringDimensions(_:)` (opt-in, `drawing()` is unchanged) rebuilds the page's
    dimensions from its loose pieces, without any flag in the file, and infers the scale from the
    values against the drawn lengths. It returns a `PDF.DimensionRecovery`: the sheet's scale
    (`sheet`, `scale`: the real value per millimetre on the paper, `80` for 1:80) with how many
    values support it and how many do not; the dimensions, each a SwiftDXF `DXF.Dimension` with its
    `rebuilt` set (the mark that says it was recovered, not stored: the pieces it was built from and
    the scale it was explained at); and per view (`views`, a `PDF.DimensionView`) the supporting and
    contradicting counts, each value text no dimension explains as a warning with its reason, and,
    where the view's own values strongly favour another scale, an `alternative` with the
    dimensions that scale would give. Nothing is scaled and nothing that the evidence does not
    settle is applied: the caller reads `scale` and the evidence, then multiplies. `rebuild` gives
    the result as SwiftDXF's `DimensionRebuild`, and `applied(to:)` adds the dimensions to a
    drawing. `PDF.DimensionOptions` takes the number convention (a Jw_cad PDF writes `1,829` for
    1829: `.commaSeparatesThousands`), a tolerance, a forced scale, the range of credible scales
    (default 10:1 to 1:300), whether arrowheads and views are used, and the gap that parts views.
    Needs SwiftDXF 0.6.0 or later, which holds the rebuild itself
    ([SwiftDXF#37](https://github.com/SecondMouseAU/SwiftDXF/issues/37)).
  - `PDF.Source` is where something came from: page, operator index, Form XObjects.
  - The library builds for macOS 15, iOS 18, visionOS 1 and tvOS 18, as OCCTSwiftIO does. PDFKit is
    not used on tvOS, so there a text run keeps the text this package's own decoding gave it (it
    may have none, and `drawing()` then counts it in `skipped["TEXT"]`, or hold a guess or a U+FFFD
    that PDFKit would have corrected).
    `Scripts/build-without-pdfkit.sh` builds for tvOS with PDFKit rewritten out, which CI runs.
  - `PDF.readReference(at:)` (spike tooling, macOS only) reads the drawing to compare with from a
    DXF, or from a zip holding exactly one entry, a DXF, through `/usr/bin/unzip`.
  - `PDF.compare(_:with:tolerance:)` (spike tooling) places a reference drawing of the same sheet
    on the paper, by a similarity transform fitted robustly to the texts that occur once in each
    (the pair of anchors most others agree with) and refined on the geometry, and reports how much
    of each drawing lies within the tolerance of the other, with the reference's uncovered
    geometry by layer and entity type. The result carries the fit (`scale`, `rotationDeg` and
    `translation`), which `pdfprobe dimension-pairs` uses to place the reference's dimensions on the
    paper.
- **Dimension rebuild** (`Dimensions/`): `PageDimensions.swift` runs SwiftDXF's
  `rebuildingDimensions(_:)` on a working drawing, once for the whole sheet (the scale and the
  dimensions) and once with each view on a layer of its own (to say where a view disagrees).
  Every entity is moved onto the sheet's or the view's layer first, since a PDF's layers say
  nothing about scale and SwiftDXF looks for a dimension's pieces on the layer of its text. A scale
  outside `scaleRange` is not used. `Arrowheads.swift` adds the tip of each arrowhead, a filled
  triangle that is a path's only subpaths and is narrow like an arrow, as a point (SwiftDXF's mark
  at the end of a dimension line), and only where no piece meets the line near the
  tip: an arrowhead beside an extension line says nothing new, and extra marks gave the rebuild
  more spans to explain a value by chance. `Views.swift` splits the drawing into views by 8-connected
  cells of twice the median text height, so views are told apart by a gap of one to two cells.
  `DimensionRecovery.swift` holds the public result and option types.
- **Interpreter** (`Interpreter/PageInterpreter.swift`): runs a page's content stream through
  `CGPDFScanner`, keeping the graphics state stack, the current path, the text state, marked
  content (`BDC /OC` and a Form XObject's `/OC` become layers) and Form XObjects (followed with
  their matrix and resources, at most 16 deep, never into themselves). Colours are read in device,
  calibrated, ICC-based and Separation spaces; others draw black.
- **Fonts** (`Fonts/`): how a font's bytes split into codes (one byte, two, Shift-JIS lead bytes,
  or the code space of a CMap), each character's advance (`Widths`, `W`, `DW`), and decoding:
  `ToUnicode` (a code it does not cover takes the font's own character when that is known, and
  U+FFFD otherwise), Shift-JIS (`*-RKSJ-*`), Unicode CMaps, and simple encodings
  (`WinAnsiEncoding`, `MacRomanEncoding`, `StandardEncoding`, `Differences` with standard glyph
  names). In a symbolic, TrueType, Type 3 or embedded font with no base encoding, codes the
  `Differences` array does not name are read as ASCII and marked `asciiGuess`.
  An `Identity` CID font that has no `ToUnicode` map and embeds a TrueType program (`FontFile2`) is
  read from the program (`FontCharacters.swift`): the code is a CID, the `CIDToGIDMap` gives its
  glyph, and the font's own Unicode `cmap` (formats 4 and 12) gives the character, marked
  `embeddedFont`. A code with no character is U+FFFD, except a space the subset left out, which is
  read as a space where the font has shown its CIDs are Unicode (at least two resolve, and every one
  resolves to itself). A font that has a map keeps it, gaps included; CFF programs (`FontFile3`) and
  other encodings are not read this way.
- **Text pairing** (`TextPairing.swift`, `TextPairing+PDFKit.swift`): on every platform but tvOS
  (the asking is behind `#if canImport(PDFKit) && !os(tvOS)`), asks PDFKit for each run's characters
  (inside its box for a run along or across the page, from its first character to its end for an
  inclined one), as a check on this reader's decoding and as its fallback where this reader has no
  characters. For a run along or across the page, PDFKit's characters also replace guessed ASCII
  they contradict and a reading with U+FFFD; an inclined run's axis-aligned box can take in its
  neighbours, so there they never replace this reader's own reading and fill in only when they
  number its codes.
- **Text assembly** (`TextAssembly.swift`): joins runs that continue one another along a baseline,
  since some writers show one character per operation.
- **Comparison support** (`Comparison+Sampling.swift`, `Similarity.swift`, `SegmentIndex.swift`):
  drawings as straight segments sampled at a fixed step, the similarity fit (least squares, and
  robust with a fixed-seed sampler so results repeat), and a grid index for nearest-segment queries.
- **`pdfprobe`** (executable): `pdfprobe [--detail] <file-or-folder>...` reports what each PDF is
  made of; `pdfprobe compare <pdf> <dxf-or-zip>` and `pdfprobe pairs <folder>` compare PDFs with
  the DXFs of the same drawings, or with their JWWs where the DXF is missing (read through
  SwiftJWW at full size, without Jw_cad's auxiliary lines and colours, number 9);
  `--exclude-layer <name>` leaves a DXF layer out, and `pairs` ends with the figures the experiment
  page reports; `pdfprobe debug-text <pdf> <text>` shows where
  this reader and PDFKit each put a text. `pdfprobe dimensions [--detail] [--numbers
  thousands|decimal|plain] [--scale N] [--scale-range LOW HIGH] [--tolerance MM] [--no-views]
  [--view-gap MM] [--no-arrowheads] <file-or-folder>...` reports the dimensions, the scale and the evidence of each
  PDF's first page; `pdfprobe dimension-pairs <folder>` rebuilds the dimensions of each PDF and of
  the DXF (or JWW) beside it and compares them by text and by the place of both ends, and the scale
  with the one the geometry fit found
  ([the experiment](../experiments/dimensions-and-scale.md)).
