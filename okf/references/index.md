---
type: reference
title: References index
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [index]
description: The PDF format, the research behind the design, and what results are checked against.
timestamp: 2026-11-23
---

# References

## The format and the frameworks

- **ISO 32000 (PDF)**: the content-stream operators, graphics state, text state, fonts, optional
  content (layers) and Form XObjects this package interprets.
- **Apple Quartz 2D, "Parsing PDF Content"**:
  <https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_pdf_scan/dq_pdf_scan.html>.
  `CGPDFScanner` calls back for each operator registered in a `CGPDFOperatorTable` and keeps no
  state, so the graphics and text state are this package's job.
- **PDFKit**: decoded page text with character positions (`PDFPage.string`,
  `characterBounds(at:)`, `selection(for:)`).

## Research behind the design (2026-11-18)

A deep-research pass and a probe of real drawing PDFs, run from OCCTDesignLoop. The points that
shaped this package:

- **Licences.** Poppler and Xpdf are GPL and MuPDF is AGPL, so none may be linked. PDFium is
  BSD-3/Apache-2.0 and stays in reserve as Option 2; `bblanchon/pdfium-binaries` (MIT) ships
  builds for Apple Silicon.
- **su-pdfimporter** (MIT), <https://github.com/bluecollar-systems/su-pdfimporter>: a small
  self-written content-stream interpreter (Bezier flattening, circle fitting, PDF layers, Form
  XObjects). A reference design, young and with one maintainer, not a dependency.
- **AutoCAD's PDF import**
  (<https://help.autodesk.com/cloudhelp/2025/ENU/AutoCAD-LT/files/GUID-F94D7059-5B4A-4396-97FE-765B1D037D56.htm>)
  sets the feature bar: arcs, circles and ellipses fitted within a tolerance, dashes merged into
  line types (and mistaken for underlined text), arrowhead solids recognised, patterned hatches
  arriving as loose pieces. Fitted geometry is tagged `FITTED` here, never `DRAWN`.
- **Text-first dimension recognition** (Wang, Tang and Tang, about 2000): find the value text, then
  the dimension line and extension lines beside it. The JWW rebuilder in SwiftJWW anchors the same
  way.
- **Vision-language models only propose** (MechVQA, arXiv 2605.30794): the best models still get
  roughly 9 to 21 percent of dimension and annotation questions wrong.

What eight real drawing PDFs contained (probed with `CGPDFScanner`):

| Producer | Arcs | Text | Layers |
|---|---|---|---|
| Jw_cad via Acrobat PDFWriter (TECS 2120) | runs of short lines | real text, Shift-JIS (`90ms-RKSJ-H`) | none |
| AutoCAD (Pandrol) | some curves | none as text; drawn as geometry | yes |
| ODA (Shapr3D) | curves | real text, no `ToUnicode` map; read from the embedded font's `cmap` | yes |
| MicroStation | curves | real text plus filled shapes | none |
| iText (two files) | runs of short lines | real text | none |
| Acrobat PDFWriter (UK railway) | runs of short lines | filled outlines, no text | none |
| Microsoft Print to PDF | curves | almost all outlines | none |

## The corpus

`PDF_CORPUS`, default `~/Projects/OCCTDesignLoop/drawingfiles` (not in any repository):

- `PDFs/`: the McMaster PDFs, the Fowler set, the UK railway sheets and the eight probed files.
- `tecs-pairs/`: the TECS drawings (from the TECS CAD site, `http://tecs.g2.xrea.com/`, whose
  drawings are published as PDF, DXF and JWW), 461 PDFs, each beside `<name>_dxf.zip` or, where
  the site's DXF link is dead, `<name>_jww.zip`. These are the paired ground truth the ecosystem
  plan's Phase 4 gate asks for; the Hankyu sheets among them are bitmap PDFs with exact DXFs,
  ground truth for scans. The site states no licence, so none of it is committed anywhere.
