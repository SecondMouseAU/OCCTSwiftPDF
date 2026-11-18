---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [index]
description: Public modules and API surfaces exposed by OCCTSwiftPDF.
timestamp: 2026-11-18
---

# Components

- **`OCCTSwiftPDF`** (library). It re-exports SwiftDXF, whose `DXF.Drawing` is what a PDF is read
  into.
  - `PDF.read(contentsOf:maximumPages:)` reads a document into `PDF.Document`: per page, painted
    `PDF.Path`s (subpaths of lines and Bezier curves in page coordinates, with paint, line width,
    dash, colours, layer and source), `PDF.TextRun`s (characters, how they were decoded, origin,
    direction, size, width, box, font, visibility, layer, source), placed `PDF.Image`s, and counts
    of clip paths, Form XObjects, inline images and shadings. The document also lists the layers
    (optional content groups) its catalog declares.
  - `PDF.Page.kind` says whether a page is `vector`, `raster` (a scanned sheet), `mixed` or
    `empty`, from the fraction of the page images cover (`imageCoverage`) and the number of
    segments drawn.
  - `PDF.Page.drawing()` turns a page into a `DXF.Drawing` in millimetres on the upright sheet:
    lines, polylines and one degree-3 spline per Bezier curve (so SwiftDXF's
    `Entity.fitted(tolerance:)` can fit arcs), and text. Each entity's identity names the page,
    the operator and any Form XObjects it came through (`p1:op120`, via `Fm0#1`). Filled-only
    paths, images and text with no characters are counted in `skipped` by layer.
  - `PDF.Source` is where something came from: page, operator index, Form XObjects.
  - `PDF.compare(_:with:tolerance:)` (spike tooling) places a reference drawing of the same sheet
    on the paper, by a similarity transform fitted robustly to the texts that occur once in each
    (the pair of anchors most others agree with) and refined on the geometry, and reports how much
    of each drawing lies within the tolerance of the other, with the reference's uncovered
    geometry by layer and entity type.
- **Interpreter** (`Interpreter/PageInterpreter.swift`): runs a page's content stream through
  `CGPDFScanner`, keeping the graphics state stack, the current path, the text state, marked
  content (`BDC /OC` and a Form XObject's `/OC` become layers) and Form XObjects (followed with
  their matrix and resources, at most 16 deep, never into themselves).
- **Fonts** (`Fonts/`): how a font's bytes split into codes (one byte, two, Shift-JIS lead bytes,
  or the code space of a CMap), each character's advance (`Widths`, `W`, `DW`), and decoding:
  `ToUnicode`, Shift-JIS (`*-RKSJ-*`), Unicode CMaps, and simple encodings (`WinAnsiEncoding`,
  `MacRomanEncoding`, `Differences` with standard glyph names, ASCII).
- **Text pairing** (`TextPairing` in `PDF+Read.swift`): asks PDFKit for the characters inside each
  run's box, as a check on this reader's decoding and as its fallback.
- **Text assembly** (`TextAssembly.swift`): joins runs that continue one another along a baseline,
  since some writers show one character per operation.
- **`pdfprobe`** (executable): `pdfprobe [--detail] <file-or-folder>...` reports what each PDF is
  made of; `pdfprobe compare <pdf> <dxf-or-zip>` and `pdfprobe pairs <folder>` compare PDFs with
  the DXFs of the same drawings.
