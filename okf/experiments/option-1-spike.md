---
type: experiment
title: Option 1 spike, Apple's frameworks only
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [spike, pdf, cgpdfscanner, pdfkit, vector]
description: CoreGraphics' PDF scanner with this package's own font decoding reads CAD-exported vector PDFs into DXF.Drawing, matching 289 of 321 TECS pairs to hundredths of a millimetre; PDFium is not needed. Text drawn as shapes is the gap, and the bridge to scans.
timestamp: 2026-11-22
---

# Option 1 spike: Apple's frameworks only

**Status: done, 2026-11-18. Verdict: Option 1 is enough; PDFium is not needed.**

The reader interprets each page with `CGPDFScanner`, keeps the graphics and text state itself,
decodes text with its own font decoding, and asks PDFKit for the characters in each run's box as
a check and a fallback. Arc recovery, dimension rebuilding, scale inference and the OCCTSwiftIO
wiring were left out on purpose.

## The corpus

`~/Projects/OCCTDesignLoop/drawingfiles`: 47 PDFs in `PDFs/` (the McMaster sheets, the Fowler
set, UK railway sheets, a model engineering set and eight probed files from as many CAD programs
and PDF writers), and
the TECS drawings in `tecs-pairs/`, each a PDF beside a zipped DXF of the same drawing.

## Results

### 1. Vector, raster or mixed

`PDFs/` (47 files): 43 vector; 3 mixed (`07B-18-00-A3.pdf` and `MAURICIUS-A3.pdf`, drawings over
full-page images, and the three-page `h-potty-mill-engine` file); and the four-page
`h-potty-mill-engine` file, mixed on three pages and raster on one. The images are real (2048 by
1444 pixels in `MAURICIUS-A3.pdf`); two of these files hold them as inline images, which count
towards a page's image coverage like image XObjects. The McMaster sheets carry a logo image of 3 to
6 percent of the page; the threshold for vector is images under a quarter of the page. The TECS
PDFs include scans: see the pairs below.

All 47 files read in a few seconds in a release build (the summary reads the first five pages of a
longer file).

### 2. Text

This reader's own decoding covered every text run in the corpus except those in two embedded
fonts without a `ToUnicode` map (ODA's, and a Japanese font on the Fowler sheets):

| Writer | Font encoding | Decoded by |
|---|---|---|
| Jw_cad through Acrobat PDFWriter 3.0J (TECS 2120) | `90ms-RKSJ-H`, not embedded | Shift-JIS, all 212 runs |
| SOLIDWORKS (McMaster) | Identity-H with `ToUnicode` | `ToUnicode` |
| DraftingCAD through Quartz (Fowler) | TrueType, `WinAnsiEncoding`; Identity-H with `ToUnicode`; one to four runs per sheet in HiraginoSans (Type 0, no `ToUnicode`) | simple encoding, `ToUnicode`; the HiraginoSans runs by PDFKit, except three on one sheet that nothing decodes |
| iText, PDFWriter (UK, model engineering) | TrueType and Type 0 with `ToUnicode` | simple encoding, `ToUnicode` |
| ODA (Shapr3D) | Identity-H, no `ToUnicode` | nothing: neither this reader nor PDFKit |

- **PDFKit agrees.** Where both decode a run, they give the same characters (McMaster 13 of 13,
  the 2120 28 of 30, the two that differ being two `1,956` values PDFKit runs together). PDFKit's
  `characterBounds(at:)` indexes its own character list, not `PDFPage.string`, which has spaces and
  line breaks added: pairing by string index gave neighbouring characters. Pairing goes through
  `selection(for:)` with a box from the baseline to three quarters of the size, since PDFKit takes
  a character when the centre of its box is inside.
- **Positions are right.** A run's origin and width match PDFKit's selection bounds exactly
  (`CROSSHEAD` on a Fowler sheet: x 640.523, width 50.665 from both).
- **One character per operation.** The Jw_cad PDFs show each character with its own `Tj`, so
  `10,439` exists only once runs are joined along their baseline (`TextAssembly`). After joining,
  the 2120's 212 runs are 33 lines, among them every dimension value. Runs in different fonts are
  not joined, so each keeps the way it was decoded.
- **Invisible text.** MicroStation (`TS.pdf`) and one PDFWriter sheet (`repw618j.pdf`) draw their
  text as shapes and lay the same text invisibly (render mode 3) over it: 3,982 and 2,249 runs,
  every one decoded, including the dimension values. The drawing keeps invisible text, since it is
  then the only text there is.
- **Undecodable: ODA.** `Wing Triple.pdf` uses an embedded TrueType subset with Identity-H and no
  `ToUnicode`, and PDFKit gives no characters either. The embedded font has a `cmap` table and a
  `CIDToGIDMap` stream, so its text can be recovered from the font itself (code to glyph, glyph to
  character) without OCR. Not done in the spike; the test pins the current behaviour.
- **Text drawn as shapes, with no text layer.** AutoCAD (`Pandrol`, SHX text as strokes), Acrobat
  PDFWriter (`Repw604s`, filled outlines) and Microsoft Print to PDF draw text as geometry and give
  no text at all. These need glyph recognition: OCR on the rendered area or matching stroke fonts.
  This is where the vector path meets the raster path.

### 3. Layers

Read where the file has them: the AutoCAD sheet's six (`TEXT-0.25`, `LINE-0.20`, `TEXT-0.45`,
`border`, `Imprial to metric`, `Watermark`) and the ODA sheet's four, from `BDC /OC` marked
content and the catalog's `OCProperties`. The Jw_cad, SOLIDWORKS, MicroStation and other exports
have none; for those, pen colour, width and dash are what is left to group by.

### 4. Form XObjects

Followed with their matrix and resources; the AutoCAD sheet draws inside one. Each entity's
identity names the forms it came through (`via ["Fm0#1"]`).

### 5. Geometry against the paired DXF

`pdfprobe compare` places the DXF on the paper by a similarity transform fitted to the texts that
occur once in each drawing, and measures, every 0.25 mm along each drawing, the distance to the
other. Two things were needed for the fit to hold:

- **A robust start.** Values repeat on a sheet, so some texts that occur once in each drawing are
  different texts that happen to match, and a least-squares fit over all of them can fail (one TECS
  sheet came out at 3 degrees and 1:169). The start is the transform fitted to a pair of anchors
  that the most anchors agree with, within 2 mm.
- **A refinement on the geometry.** Texts are placed by different reference points in different
  formats, which left a 0.19 mm offset. The fit is refined by matching each drawing's geometry to
  the nearest of the other's.

The DXF's Jw_cad auxiliary lines (layer `ADD_LINE` in the TECS DXFs: dotted boxes round texts and
construction lines) are left out, since Jw_cad never prints them.

**The 2120** (PDF printed from Jw_cad, against the DXF written from its JWW by SwiftJWW): scale
1.00003, rotation 0.00 degrees, geometry residual 0.025 mm. The PDF's geometry is all within 0.2 mm
of the DXF's. The DXF's is too, except a box of seven lines on JWW layer 15 that was not printed
(336 mm of line, 2 percent of the drawing): 98.0 percent covered in all, 99.96 percent without that
box. Median distance 0.019 mm, 90th percentile 0.039 mm, on the paper; at 1:80 that is about 1.5 and
3 mm at full size. 31 of the 34 texts match within 2 mm. Through the TECS JWW of the same drawing
(`pdfprobe compare` on `2120_jww.zip`, full size, without Jw_cad's auxiliary lines, which also drops
that unprinted box), the fit is 1:80 and both sides are 100 percent covered, with the 99th
percentile at 0.049 mm.

**The TECS pairs.** The TECS site lists 556 drawings, 457 of them published as PDF, DXF and JWW
and 3 as PDF and JWW only. A crawl of its pages found 204 pairs the corpus did not have, and
`tecs-pairs/` now holds 461 PDFs. Some of the site's links are dead (its 404 page is what the 13
broken zips held): where a drawing's DXF link is dead, its JWW is the reference instead, read by
SwiftJWW at full size without Jw_cad's auxiliary lines and colours (`pdfprobe` only). On `ec01`,
which has both, the JWW route gives the same result as Jw_cad's own DXF export (99.1 and 100
percent covered, median 0.007 mm, 107 of 107 texts), so either is a sound reference.

`pdfprobe pairs --exclude-layer ADD_LINE` over the whole folder:

- 131 not compared, all for want of text in common: the 118 Hankyu sheets (`hk*`), which are
  bitmaps (the drawing printed as strips of 1-bit images at 850 dots per inch, through the Windows
  PostScript driver and Acrobat Distiller), 12 other scanned sheets, and 1 PDF that does not open.
  The Hankyu sheets with their exact DXFs are ready-made raster ground truth for Phase 5.
- 326 compared (311 against a DXF, 15 against a JWW), 321 of them single-page. For **289 of the
  321, each drawing is at least 95 percent within 0.2 mm of the other**; in those, the median
  distance is 0.010 mm and the 90th percentile 0.024 mm on the paper. 23,110 of 24,643 texts match
  within 2 mm. Through a JWW, 13 of 15 pass.
- By section: JNR electric (`cad/tu`) 133 of 140, passenger cars (`cad/pc`) 30 of 31, freight
  (`cad/pf`) 66 of 77, diesels (`cad/dl`) 11 of 13, bogies, pantographs and parts (`truck/cad`) 32
  of 35, steel sections (`kouzai`) 15 of 19, markings (`hyouki`) 2 of 6.
- The fits found the sheets' scales: 1:80 (146), 1:100 (88), 1:50 (26), 1:30 (18), 1:10 (16), 1:64
  (10), 1:20 (7), down to 1:2 for parts, and 20:1 for a sheet of screw threads.
- One writer, MicroArts JWtoPDF (the steel-section and parts sheets), draws a frame on the page's
  own edge that is not in the drawing; `drawing()` now leaves it out (`skipped["PAGE BORDER"]`),
  which took those sheets from 53 to 75 percent on the PDF side to 100.
- The 32 short of 95 percent: in 15 only the DXF side is short (the DXF holds more than the sheet
  printed, as on the markings sheets); in 5 only the PDF side; in 12 both. Those 12 are the pairs
  whose files hold different extents or versions of the sheet (`c5000x`, `ec33`, `ec34`, and
  `dd20-1`, whose JWW and PDF fit only at 1:84 and 0.6 degrees), and a family of wagon drawings
  (`tm*`, `tr*`, `to20000*`) near 88 percent both ways with the fitted scale 0.08 percent off the
  nominal, not yet looked into.
- The multi-page PDFs are compared on their first page while the DXF holds every sheet, so about
  half the DXF is missing by design; their PDF side is 100 percent covered.

Nothing found points at the reader: where geometry is missing, it is missing from one file, not
lost by the interpretation.

### Arcs (out of scope, one finding)

Curves come through as degree-3 splines, and SwiftDXF's `Entity.fitted(tolerance:)` turns them
into arcs within the tolerance. It holds position, not radius: a one-inch circle drawn as four
curves came back as eight arcs of radius 25.29 mm against 25.4 at a tolerance of 0.01 mm. Values
for the ledger need a direct test that a run of curves, or of short lines, is one circle, with the
radius fitted over the whole run.

### Known limits of the spike reader

- Clipping paths and a form's bounding box are not applied, so geometry a printer would clip away
  is still in the drawing.
- Layers the document turns off by default are read like the others; `Document.layersOff` lists
  them.
- Vertical writing (`-V` CMaps) is advanced horizontally.
- Character widths in fonts with a predefined CMap other than Identity use the font's default
  width, since the code-to-CID tables are not carried.
- The PDFKit pairing assumes PDFKit's page coordinates are the PDF's own; this was checked on
  sheets whose page box starts at the origin. A run along or across the page is asked for through
  an axis-aligned box; an inclined run, whose box would take in its neighbours, from a point inside
  its first character to its end, which follows PDFKit's text flow along the run, and is filled
  only when the characters number its codes.
- Colours in Indexed, Pattern, DeviceN and Lab spaces are drawn black; device, calibrated,
  ICC-based and Separation colours are read.
- The comparison's reference reader runs `/usr/bin/unzip`, so it is macOS only.
- A code a `ToUnicode` map does not cover takes the font's own character when its encoding is
  known, and U+FFFD otherwise, rather than being dropped. Codes from a symbolic, TrueType, Type 3
  or embedded font with no encoding are only guessed to be ASCII (`TextDecoding.asciiGuess`).
  PDFKit's characters replace a guess or a U+FFFD where the two differ, for runs along or across
  the page; for an inclined run they only fill in where this reader has none.

## Decision

Option 1 holds. CoreGraphics' scanner gives exact geometry, and this package's own font decoding
covers every font in the corpus except embedded fonts without a `ToUnicode` map, whose fix is in
the font file itself (its `cmap` table). PDFKit is worth
keeping as a cross-check and a fallback, through selection boxes only. PDFium would add a large
binary for nothing the corpus needs.

## Next

1. Recover the ODA text from the embedded font's `cmap`.
2. Arc and circle recovery from curves and from runs of short lines, tagged `FITTED` with the
   residual, radius fitted over the whole run.
3. Dimension rebuilding without Jw_cad's flags (shared with OCCTSwiftIO#72): value text first, then
   the dimension line, arrowheads (filled-only paths, kept now as `skipped["FILL"]`) and extension
   lines.
4. Scale inference from values against drawn lengths, per view.
5. Wire into OCCTSwiftIO's `DrawingLoader` as `.pdf`. This package is public and LGPL-2.1 like
   OCCTSwiftIO, which builds for iOS, visionOS and tvOS. The PDFKit use is now guarded (older
   tvOS SDKs have no PDFKit, [#3](https://github.com/SecondMouseAU/OCCTSwiftPDF/issues/3)) and the comparison's
   `unzip` reader is macOS only, so the package builds on all four; what is left is the wiring and
   a first tag to pin.
6. Text drawn as shapes: OCR on the rendered area (Apple Vision), accepted only where it agrees
   with the measured geometry. The first piece of the raster path.
