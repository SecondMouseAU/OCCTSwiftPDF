---
type: experiment
title: Option 1 spike, Apple's frameworks only
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [spike, pdf, cgpdfscanner, pdfkit, vector]
description: CoreGraphics' PDF scanner with this package's own font decoding reads CAD-exported vector PDFs into DXF.Drawing, matching 289 of 321 TECS pairs to hundredths of a millimetre; PDFium is not needed. Text drawn as shapes, which has no text to read, is recovered by opt-in OCR where it agrees with the geometry; the first piece of the raster path.
timestamp: 2026-11-23
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
- **Text drawn as shapes, recovered by OCR (opt-in, Next 6).** `PDF.Document.recoveringShapeText()`
  finds lines of small filled or stroked shapes from the geometry already read, renders the page
  (CoreGraphics) and cuts each line out upright, reads it with Apple Vision at three sizes, and
  keeps the text only where it agrees with the shapes: the recognised box overlaps theirs (at least
  0.5 intersection over union), runs along their direction (within 8 degrees) and is 0.6 to 1.8 of
  their height, the number of characters is plausible for the number of glyph pieces, the length
  fits the number of characters, the characters are plausible (a letter or digit, no replacement
  character, no Latin and Cyrillic in one word, nothing outside the blocks a drawing's text is in),
  and all three readings give the same characters. The rest is counted with its reason. Accepted
  text is a run decoded `.ocr` with the recogniser's confidence, and a drawing marks it `:ocr` in
  the entity's identity. Measured with Vision on macOS 27.2 (the output differs by OS version), page
  1 unless said, the shipped defaults:

  | Sheet | How the text is drawn | Clusters | Accepted | Rejected, and why | Checked against |
  |---|---|---|---|---|---|
  | `Repw604s` | Acrobat PDFWriter 3.02, filled outlines, no text layer | 308 | 176 | 132: no text 79, readings disagree 17, position 14, direction 6, ambiguous 6, glyph count 4, characters 4, confidence 2 | 52 accepted strings checked by eye against the page rendered by `pdftocairo`: about one in six wrong |
  | `repw618j` | same writer, strokes, invisible text layer | 1,957 | 1,114 | 843: no text 537, readings disagree 184, position 28, direction 27, confidence 26, glyph count 16, characters 14, ambiguous 11 | the text layer, below |
  | `TS.pdf`, 20 pages | MicroStation through Adobe PDF Library, outlines, invisible text layer | 3,657 | 2,313 | 1,344: no text 729, position 217, readings disagree 162, ambiguous 126, direction 63, characters 19, confidence 19, glyph count 8, height 1 | the text layer, below |
  | `a3012183-...` | Microsoft Print to PDF, outlines | 203 | 123 | 80: no text 36, readings disagree 22, position 9, ambiguous 6, direction 3, confidence 2, characters 1, glyph count 1 | no text layer; 16 of 16 sampled right |
  | `Pandrol...` | AutoCAD plot, SHX strokes | 200 | 98 | 102: no text 72, position 9, readings disagree 7, direction 7, ambiguous 3, characters 2, confidence 1, already read 1 | no text layer; 15 of 16 sampled right (`RAL` for `RAIL`) |

  A cluster is one line of at least two glyph pieces; "too small" clusters (a single piece) are
  counted apart and not looked at (556 on `repw618j`).
  - **Against the text layer** (`pdfprobe ocr --compare`, which recognises the clusters over the
    invisible text as well and compares the accepted string with it, ignoring spaces). On
    `repw618j`, 1,083 accepted clusters lie over text the page has: 691 give the same characters, 358
    are a word or part of a longer run's text, 34 (3.1 percent) differ. On `TS.pdf`, 2,208:
    1,301 the same, 868 a part, 12 the page's text is a part of the OCR, 27 (1.2 percent) differ.
    Position: the accepted cluster's centre is inside or within 0.58 mm of a text run's box in every
    case. Of the 34 on `repw618j`, 25 are `L/R` read as `LYR` or `LVR` (the slash), 5 are a
    fraction read as `½` or `¾`, one is a Cyrillic `Х-Х` for `X-X`, and 3 are other fragments; of the
    27 on `TS.pdf`, 8 are `W.Ariyaratne` with its full stop lost, 11 are the centre-line sign read
    as `&`, `*` or `E` (the text layer has a replacement character there), 5 are superscripts
    (`x 10^7`) and 3 other. Where the text layer is itself wrong (mojibake for `°` and `¶`) the OCR
    is the likelier right.
  - **What three readings buy.** In an earlier build, on `repw618j` one reading (40 pixels high)
    accepted 1,247 clusters over text, 121 of them (9.7 percent) different; the three agreeing readings accepted 1,070, 31
    (2.9 percent) different, and lost about 14 percent of the accepted number, some of them right
    (of the 241 clusters recognised and rejected on this sheet, 124 were right anyway). It does not
    help against a confusion at every size, as the slash is.
  - **Where there is no text to find.** Of the 47 corpus files, 38 accept nothing from their first
    page: the McMaster and Fowler sheets, `2120`, `Wing Triple` and others, all with real text. Of the
    other nine, five are the sheets above, three are Repw sheets with real text and some of it
    outlined (`repw617d`, `repw762d` and `repw810c` accept 3, 10 and 18), and one is
    `MAURICIUS-A3.pdf`, a drawing over a full-page image, which accepts `AD` twice from shapes that
    are not text: the one case found of OCR text from shapes that are not text.
  - **Pairs.** None of the 326 TECS pairs compared has text drawn as shapes (every vector TECS sheet
    has text), so there is no DXF or JWW of a drawing like this to compare with; the text layer of
    `repw618j` and `TS.pdf` is the check, and the geometry of a paired drawing is unchanged.
  - **Cost.** `repw618j` (15,430 small shapes, 1,957 clusters) takes 60 to 130 seconds with three
    readings, `TS.pdf` (20 pages) 1 to 5 minutes, depending on the load of the machine; the first
    Vision call after a boot takes about 30 seconds more.

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
- A font read from its embedded program (`embeddedFont`) is taken at its word: a writer whose
  Unicode `cmap` is not the real character mapping would give wrong text, which only the decoding
  says apart from `toUnicode`; private-use code points are not read as characters. Only TrueType
  programs (`FontFile2`) are read, from `cmap` formats 4 and 12, and only where the font has no
  `ToUnicode` map (or, if composite, an empty one); one that has a map keeps it, gaps included.
  Where a `CIDToGIDMap` stream does not show the CIDs to be Unicode, a space the subset left out is
  U+FFFD. One corpus file reaches this path, so how far it generalises is not measured.
- Text recovered by OCR (`PDF.Document.recoveringShapeText`, opt-in) is only as good as Vision,
  whose output differs by OS version and machine (the figures here are from macOS 27.2). It can read
  a character that looks like another as that one where the geometry cannot tell (`/` as `V` in
  `L/R`, `&` as a dot, a character under a ruling line), and Vision reports a confidence of 1.0 for
  nearly everything, so the confidence tells nothing: `.ocr` text is unchecked text. Any other ink
  under a line (a ruling line through a word) reaches the recogniser with it. Not looked at:
  clusters of fewer than two glyph pieces (a lone character cannot be checked), a line of two
  glyphs at an angle that is not along or across the page (the principal axis needs three), shapes
  over 64 page units, and pieces in a blob of more than 5,000 glyphs (hatching) or on a page so
  dense that grouping them would take too long. Three or more characters that are all plain
  vertical strokes (`I`, `l`, `1`, `|`, `!`) are refused, since a row of ticks reads that way, and
  that refuses a value such as `111` with them. A gap wider than a glyph cuts a line
  into words, each its own run; lines are not joined into blocks; a page's images are rendered under
  the shapes (a drawing over a full-page image gave two accepted strings that are not text), and
  superscripts and `1/2` come back as the recogniser writes them (`½`). An OCR run's `height` is
  the ink above its baseline, not a font size, and the baseline is estimated from where most
  glyphs stand. The first Vision call after a boot takes tens of seconds while the system loads its
  model.
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
2. Arc and circle recovery from curves and from runs of short lines, tagged `FITTED` with the
   residual, radius fitted over the whole run.
3. Dimension rebuilding without Jw_cad's flags (shared with OCCTSwiftIO#72): value text first, then
   the dimension line, arrowheads (filled-only paths, kept now as `skipped["FILL"]`) and extension
   lines.
4. Scale inference from values against drawn lengths, per view.
5. Wire into OCCTSwiftIO's `DrawingLoader` as `.pdf`. This package is public and LGPL-2.1 like
   OCCTSwiftIO, which builds for iOS, visionOS and tvOS. The PDFKit use is now guarded and off on
   tvOS ([#3](https://github.com/SecondMouseAU/OCCTSwiftPDF/issues/3)), and the comparison's `unzip`
   reader is macOS only, so the package builds on all four; what is left is the wiring and a first
   tag to pin.
6. Done: text drawn as shapes is recovered by OCR on the rendered area (Apple Vision), accepted only
   where it agrees with the measured geometry (`PDF.Document.recoveringShapeText`, opt-in; the
   figures are in Results, section 2). It is the first piece of the raster path: its render and
   recognise steps are what the scanned sheets will use. What it leaves: a check of each recognised
   character against the ink it was read from (which would catch the look-alikes it passes), reading
   a cluster from its own shapes without the other ink under it, and joining lines into blocks.
