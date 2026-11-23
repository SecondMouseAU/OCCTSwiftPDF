---
type: experiment
title: Option 1 spike, Apple's frameworks only
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [spike, pdf, cgpdfscanner, pdfkit, vector]
description: CoreGraphics' PDF scanner with this package's own font decoding reads CAD-exported vector PDFs into DXF.Drawing, matching 289 of 321 TECS pairs to hundredths of a millimetre; PDFium is not needed. Text drawn as shapes is the gap, and the bridge to scans.
timestamp: 2026-11-23
---

# Option 1 spike: Apple's frameworks only

**Status: done, 2026-11-18. Verdict: Option 1 is enough; PDFium is not needed.**

The reader interprets each page with `CGPDFScanner`, keeps the graphics and text state itself,
decodes text with its own font decoding, and asks PDFKit for the characters in each run's box as
a check and a fallback. Dimension rebuilding, scale inference and the OCCTSwiftIO wiring were
left out on purpose; arc recovery was left out of the spike and has since been added
(`fittedDrawing()`, see Arcs below).

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

This reader's own decoding covered every text run in the corpus except those in a Japanese font
on the Fowler sheets (a Type 0 font with no `ToUnicode` map), which PDFKit reads, except three runs
on one sheet that nothing decodes:

| Writer | Font encoding | Decoded by |
|---|---|---|
| Jw_cad through Acrobat PDFWriter 3.0J (TECS 2120) | `90ms-RKSJ-H`, not embedded | Shift-JIS, all 212 runs |
| SOLIDWORKS (McMaster) | Identity-H with `ToUnicode` | `ToUnicode` |
| DraftingCAD through Quartz (Fowler) | TrueType, `WinAnsiEncoding`; Identity-H with `ToUnicode`; one to four runs per sheet in HiraginoSans (Type 0, no `ToUnicode`) | simple encoding, `ToUnicode`; the HiraginoSans runs by PDFKit, except three on one sheet that nothing decodes |
| iText, PDFWriter (UK, model engineering) | TrueType and Type 0 with `ToUnicode` | simple encoding, `ToUnicode` |
| ODA (Shapr3D) | Identity-H; `ToUnicode` is the name `Identity-H`, not a map; embedded TrueType subset with a `CIDToGIDMap` and a `cmap` | the embedded font's own `cmap`, all 55 runs; PDFKit finds nothing |

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
- **ODA, read from the font.** `Wing Triple.pdf` uses an embedded TrueType subset with Identity-H
  whose `ToUnicode` entry is the name `Identity-H`, which is not a map, so neither this reader's
  maps nor PDFKit give characters. The font has a `cmap` table (platform 3, encoding 1, format 4)
  and a `CIDToGIDMap` stream, so each code is read as CID to glyph to the font's own character
  (`TextDecoding.embeddedFont`), without OCR. All 55 runs decode, dimension values (`5,1`, `0,48`)
  and title block alike. The font shows its CIDs are Unicode: all 57 CIDs it can resolve resolve to
  themselves. A space has no outline, so the subset leaves it out of its `cmap`; where the font has
  shown its CIDs are Unicode, a space CID it cannot resolve is read as that space, and any other
  code it cannot resolve is U+FFFD. Checked against `pdftotext -raw` (a development check only;
  nothing depends on it): every run has the same characters.
  CoreText was tried first: it loads this subset and maps characters to glyphs, but only that way
  round, and only for a font it accepts whole (it refuses a font that has just a `cmap`). The table
  is read directly instead, so it does not depend on the system accepting the font and can be tested
  with small hand-built ones. Only TrueType programs (`FontFile2`) are read; CFF fonts (`FontFile3`)
  are not.
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

### Arcs

**The problem.** Curves come through `drawing()` as degree-3 splines, and SwiftDXF's
`Entity.fitted(tolerance:)` turns each into arcs within the tolerance. It holds position, not
radius: a one-inch circle drawn as four curves came back as eight arcs of radius 25.29 mm against
25.4 at a tolerance of 0.01 mm. `PDF.Page.fittedDrawing()` (2026-11-23) tests the whole run
instead: that circle comes back as one circle of radius 25.403 mm (the four curves are 0.027
percent out of round themselves), with a largest residual of 0.0036 mm, tagged `FITTED`.
`drawing()` is unchanged: its hash over every page of all 590 PDFs (entities, identities,
`skipped`) is the same before and after.

**What is taken.** One circle fitted over the whole run (least squares on the geometric distance,
not a bias-prone algebraic fit) must pass within a tolerance of every vertex and of eight samples
along every curve, the run must sweep at least 45 degrees, and a run of chords must have at least 8
of them, each at most 24 degrees, of near equal steps, that the polyline does not carry on past in
the same curve. Arcs that meet end to start on one circle in one layer and colour are joined across
subpaths and strokes and fitted again. The numbers came from the corpus, not from a guess:

- A first version (0.01 mm for every run, arcs from 4 chords and 20 degrees) found 54,271 arcs in
  the 47 files of `PDFs/`, and against the TECS DXFs only 625 of the 6,281 arcs it took from
  chords matched a reference arc (10 percent). The rest were locally round pieces of freehand
  curves, spirals (the SOLIDWORKS Acme thread on a McMaster sheet) and the arcs of ellipses: any
  smooth polyline is round to a hundredth of a millimetre over a few chords. Chords from the
  writers that flatten exactly (iText: 0.0002 mm median residual, a second cluster at
  0.005 to 0.009 for the rest) are why chords now need 0.003 mm, 8 segments and the rest.
- For arcs from curves, in that first run, the share a reference arc confirms rises with the
  sweep: 44 percent under 25 degrees, 62 at 25 to 30, 72 to 89 at 30 to 45, 93 at 45 to 60, 97
  at 60 to 90 and 98 from 90. That is why an arc must sweep 45 degrees. A shorter one stays a spline, and SwiftDXF's `fitted`
  can still turn it into arcs.
- Unit tests on hand-built runs: polygons of 3 to 14 sides, ellipses (five axis ratios, three
  chord counts), a spiral, a parabola, an S-curve and an eccentric Bezier arc are not taken; a
  rounded rectangle is four lines and four arcs of the corner radius, never one circle.

**Recovered, over the corpus** (`pdfprobe arcs`; 589 of the 590 PDFs open, 430 have at least one
circle or arc; 69,257 circles and 206,313 arcs):

| Producer | files (with fits) | circles | arcs | from curves / lines / mixed | median residual (mm) |
|---|---|---|---|---|---|
| Acrobat Distiller | 314 (177) | 49892 | 142822 | 149483 / 0 / 43231 | 0.0022 |
| Acrobat PDFWriter | 175 (169) | 5367 | 22897 | 22896 / 1 / 5367 | 0.0028 |
| Adobe PDF Library | 7 (4) | 2046 | 9421 | 11054 / 0 / 413 | 0.0044 |
| Aspose.PDF for .NET | 1 (1) | 1 | 0 | 0 / 1 / 0 | 0.0002 |
| GPL Ghostscript | 2 (2) | 0 | 447 | 387 / 0 / 60 | 0.0033 |
| JUST PDF | 2 (2) | 1910 | 3387 | 4899 / 1 / 397 | 0.0029 |
| MicroArts PDF Exchange Project | 35 (35) | 6844 | 19407 | 26251 / 0 / 0 | 0.0001 |
| Microsoft: Print To PDF | 1 (1) | 12 | 119 | 131 / 0 / 0 | 0.0045 |
| Microsoft PowerPoint | 7 (3) | 146 | 490 | 608 / 0 / 28 | 0.0028 |
| Nitro Pro | 1 (1) | 0 | 6 | 6 / 0 / 0 | 0.0049 |
| ODA PDF Export | 1 (1) | 3 | 0 | 3 / 0 / 0 | 0.0003 |
| Online2PDF.com | 1 (1) | 0 | 4 | 4 / 0 / 0 | 0.0012 |
| PDF-XChange Viewer [Version: | 1 (1) | 0 | 236 | 198 / 0 / 38 | 0.0028 |
| iText | 3 (3) | 1694 | 5492 | 0 / 7186 / 0 | 0.0002 |
| macOS Version | 1 (1) | 27 | 58 | 0 / 85 / 0 | 0.0002 |
| Quartz PDFContext (macOS) | 27 (27) | 1311 | 1377 | 2600 / 0 / 88 | 0.0002 |
| pdfplot12.hdi | 1 (1) | 4 | 150 | 154 / 0 / 0 | 0.0001 |

No circle or arc in the five SOLIDWORKS sheets (the McMaster sheets draw threads as spirals of
chords), nor in Acrobat Pro, Corel, doPDF and Conv2pdf output. Mixed is curves and straight
segments together, usually a circle's curves and its closing line.

**Against the paired DXF or JWW, by coordinates** (`pdfprobe arc-pairs`, 326 pairs, a reference
circle or arc within 0.15 mm of the fit's centre and radius on the paper, angles overlapping):

- 228,659 fits: 215,852 (94.4 percent) match a reference circle or arc, 7,831 are circles centred
  on a reference `POINT` (Jw_cad prints each point as a small circle: `Igata` has 161 `POINT`s
  and 161 such circles, of the same 3 mm radius), 4,976 (2.2 percent) are neither, and 2,380 of
  those (1.0 percent of all) have no reference geometry within 0.1 mm along them. Nine files
  hold 90 percent of the 2,380; seven are in the pairs listed above as holding other versions or
  extents of the sheet (`ec33`, `ec34`, `dd20-1` and the wagon family), and `dt71` and `dmh17` have
  not been looked into.
- Radius error, fit less reference, in millimetres at full size: MicroArts JWtoPDF median 0.003,
  90th percentile 0.02, and 0.0001 mm on the paper; centre error median 0.0002 mm on the paper.
  Acrobat Distiller median 0.96, 90th percentile 2.5 (at 1:50 to 1:100): its coordinates are on a
  grid of 0.06 points (1/1200 inch, 0.021 mm on the paper, as in the `ec01` content stream), the
  median error on the paper is 0.012 mm, about half a step, and the fit's own residual is
  smaller. Acrobat
  PDFWriter median 3.5: its circles are 0.03 to 0.05 mm smaller on the paper than the CAD's,
  whatever the fit, so what the file draws is not what the CAD drew. Fitting does not beat the
  writer; it stops adding error to it.
- Not recovered: 152,357 of the 364,776 reference circles and arcs have no fit. In the two pairs
  looked at about four in five sweep under 45 degrees and the rest have a radius of 0.2 to 0.5
  mm on the paper. The 2120 (Jw_cad through Acrobat PDFWriter 3.0J) has none of its 1,909
  reference circles and arcs recovered: its arcs are runs of a few chords (4 to 6 in the ones
  looked at), too few to take. No flattened circle was found in any TECS pair, so how well chords
  are recovered is measured only by unit tests and by the corpus's exact flatteners (iText: 1,694
  circles, 5,492 arcs), which have no reference.
- Joining matters for DraftingCAD through Quartz (the Fowler sheets), which draws each circle as
  two half circles in two strokes with different pens. Over the 47 files of `PDFs/` the circles
  went from 3,203 (runs inside one subpath only) to 3,287 with joining and the rule that a circle
  drawn a little past its start is still a circle (Quartz 1,293 to 1,311, iText 1,631 to 1,694).
  Arcs that still meet on one circle but were not joined (743 pairs over the corpus, mostly the
  strokes of text drawn as shapes) have more than one neighbour, another layer or colour, or no
  circle that fits them all.

Not done: elliptical arcs and ellipses are not recovered (they stay splines); a circle drawn as
two strokes of different layers or colours is not joined; a flattened arc whose last chord is a
short remainder fails the equal-steps test, and a very large radius drawn with coarse rounding
(over the 2 m limit, or too flat for a few points to say) is not taken; tolerances were set on
TECS and `PDFs/` and are options (`PDF.ArcFitting`), not measured on other writers.

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
- A font read from its embedded program (`embeddedFont`) is taken at its word: a writer whose
  Unicode `cmap` is not the real character mapping would give wrong text, which only the decoding
  says apart from `toUnicode`; private-use code points are not read as characters. Only TrueType
  programs (`FontFile2`) are read, from `cmap` formats 4 and 12, and only where the font has no
  `ToUnicode` map (or, if composite, an empty one); one that has a map keeps it, gaps included.
  Where a `CIDToGIDMap` stream does not show the CIDs to be Unicode, a space the subset left out is
  U+FFFD. One corpus file reaches this path, so how far it generalises is not measured.
- On tvOS PDFKit is not used. A run only PDFKit can read (the HiraginoSans runs on the Fowler
  sheets) has no text there, and `drawing()` counts it in `skipped["TEXT"]`; a run this reader only
  guessed (`asciiGuess`) or read with U+FFFD keeps that reading, which can be wrong text, not
  missing text.
- A code a `ToUnicode` map does not cover takes the font's own character when its encoding is
  known, and U+FFFD otherwise, rather than being dropped. Codes from a symbolic, TrueType, Type 3
  or embedded font with no encoding are only guessed to be ASCII (`TextDecoding.asciiGuess`).
  PDFKit's characters replace a guess or a U+FFFD where the two differ, for runs along or across
  the page; for an inclined run they only fill in where this reader has none.

## Decision

Option 1 holds. CoreGraphics' scanner gives exact geometry, and this package's own font decoding
covers every font in the corpus except one Japanese font on the Fowler sheets, which PDFKit reads
(three runs on one sheet are read by nothing); an embedded font without a `ToUnicode` map is read
from the font file itself (its `cmap` table).
PDFKit is worth keeping as a cross-check and a fallback, through selection boxes only. PDFium would add a large
binary for nothing the corpus needs.

## Next

1. Done: the ODA text is recovered from the embedded font's `cmap` (`TextDecoding.embeddedFont`).
2. Done: arc and circle recovery from curves and from runs of short lines, tagged `FITTED` with
   the residual, radius fitted over the whole run (`PDF.Page.fittedDrawing()`, see Arcs). Still
   open: arcs under 45 degrees, flattened circles with a reference to check against, ellipses.
3. Dimension rebuilding without Jw_cad's flags (shared with OCCTSwiftIO#72): value text first, then
   the dimension line, arrowheads (filled-only paths, kept now as `skipped["FILL"]`) and extension
   lines.
4. Scale inference from values against drawn lengths, per view.
5. Wire into OCCTSwiftIO's `DrawingLoader` as `.pdf`. This package is public and LGPL-2.1 like
   OCCTSwiftIO, which builds for iOS, visionOS and tvOS. The PDFKit use is now guarded and off on
   tvOS ([#3](https://github.com/SecondMouseAU/OCCTSwiftPDF/issues/3)), and the comparison's `unzip`
   reader is macOS only, so the package builds on all four; what is left is the wiring and a first
   tag to pin.
6. Text drawn as shapes: OCR on the rendered area (Apple Vision), accepted only where it agrees
   with the measured geometry. The first piece of the raster path.
