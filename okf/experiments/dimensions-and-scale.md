---
type: experiment
title: Dimensions and scale from a PDF page
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [pdf, dimensions, scale, rebuild, tecs, spike]
description: A PDF page's dimensions are rebuilt from its loose pieces with SwiftDXF's rebuild, and the scale found from the values against the drawn lengths, with the evidence. On 321 TECS sheets the scale equals the geometry's fit on 311, and 15,184 of 17,884 dimensions match the paired drawing's by text and place.
timestamp: 2026-11-23
---

# Dimensions and scale from a PDF page

Items 3 and 4 of the spike's Next list (`option-1-spike.md`), shared with OCCTSwiftIO#72. A PDF holds
a dimension as separate pieces (a value text, a dimension line, extension lines, arrowheads) with
nothing that says which belong together or at what scale they were drawn.
`PDF.Page.recoveringDimensions(_:)` puts them back together and says what it rests on.

## What it builds on

SwiftDXF 0.6.0 already holds the rebuild (`DXF.Drawing.rebuildingDimensions(_:)`, SwiftDXF#37, shared
with Jw_cad DXF and DWG exports): from each value text it finds the dimension line beside it, the
ends that line spans (where an extension line meets it, or an end mark is), the circle or arc of a
diameter or radius, the scale that explains the most values (a least-squares scale made round when
that is within what the values can tell apart), and a warning for each value it cannot explain. A
rebuilt `DXF.Dimension` carries `rebuilt` (the pieces it was made of and the scale it was explained
at), which is the mark that says "recovered, not stored". This package did not need a convention of
its own, and does not invent one.

What this package adds, because a PDF is not a Jw_cad export:

- **One layer for the scale.** A PDF's layers say nothing about scale (the AutoCAD sheet has text on
  `TEXT-0.25` and lines on `LINE-0.20`), and SwiftDXF looks for a dimension's pieces on the layer of
  its text. Every entity goes on the sheet's layer (or its view's) before the rebuild, and a dimension
  gets its text's layer back.
- **Arrowheads** (`Dimensions/Arrowheads.swift`). A filled path with no stroke whose subpaths are all
  small triangles that are narrow like an arrow gives a point at the tip, where it is the only mark of
  an end. Below.
- **A range of credible scales** (default 10:1 to 1:300). Below.
- **Views** (`Dimensions/Views.swift`): the page split into pieces that lie together apart from the
  others, to say where a view's own values disagree with the sheet's. Below.
- **The evidence**: `PDF.DimensionRecovery` has the sheet's scale with its supporting and contradicting
  values, per view the same counts and each unexplained value as a warning with its reason, and any
  other scale a view's own values favour as an `alternative`, with the dimensions it would give.
  `drawing()` is unchanged, nothing is scaled, and nothing that the evidence does not settle is
  applied.

## How it was checked

`pdfprobe dimension-pairs <tecs-pairs> --exclude-layer ADD_LINE`: each PDF's first page against the
DXF (or, where the DXF is dead, the JWW) of the same drawing. The reference is rebuilt the same way
at its own full size, read the way Jw_cad writes numbers, and placed on the paper by the comparison's
fit (`PDF.compare`, which now also gives the fit's translation). A PDF dimension is *matched* when a
reference dimension has the same text and both ends within 0.5 mm of it on the paper; *moved* when
the reference has that text only elsewhere; *PDF only* when the reference has no dimension of that
text. The scale the fit found (the reference's units to paper millimetres, 1:80 for a full-size
reference of an 80th-scale sheet) is the scale the sheet is at. Where the pair is a JWW, SwiftJWW's
`recoveringDimensions()` (with Jw_cad's attribute flags, so no inference) is a second reference for
the values. Nothing is compared by picture. Before and after, `pdfprobe` over all 590 corpus PDFs and
`pdfprobe pairs` over the TECS folder give identical output: the reader is unchanged.

## Results

### The 2120

29 dimensions at 1:80, all 29 values support the scale, none contradicts it, and there is no warning.
The texts are the 29 that SwiftJWW recovers from the JWW with Jw_cad's flags
(`DimensionCorpusTests.the2120`). This meets the acceptance of OCCTSwiftIO#72 for the PDF (29 values,
1:80, supported by all 29). SwiftDXF's rebuild on `drawing()` as it was already gave the 29.

### The TECS pairs (326 compared: 311 against a DXF, 15 against a JWW)

| | count |
|---|---|
| dimensions rebuilt from the PDFs | 17,884 |
| dimensions rebuilt from the references | 16,991 |
| matched: same text, both ends within 0.5 mm | 15,184 (84.9% of the PDF's, 89.4% of the reference's) |
| moved: same text, ends elsewhere | 632 |
| PDF only | 2,068 |
| reference only | 1,175 |

- **The scale.** Of the 321 sheets whose reference has dimensions, the scale found equals the fit's
  (within 1 percent) on **311**. Four differ: `dd20-1` (its JWW and PDF fit at 1:84 and 0.6 degrees, a
  different version of the sheet; the PDF's 1:80 is the nominal), `hkloco1` (1:9.85 against 1:10),
  `renga` (1:6.12 against 1:5, all 18 dimensions matching the reference's) and `hk60000` (1:20 against
  1:50, all 8 matching): on those two the values do not follow the geometry's scale, which is the
  sheet's property, not the rebuild's. Six give none: `dt18`, `dt22c`, `dt44`, `dt44a` (see the range
  below), `ps11` (7 reference dimensions, the PDF finds none) and `tr-pc2` (see the numbers below).
  One sheet has a view that favours another scale (`es04`, view 3, 1:35 against 1:100 on 8 values),
  which is reported and not applied.
- **Moved and PDF only (2,700 dimensions, 15 percent).** Only 26 are at a scale other than the fit's
  (18 on `dd20-1`, whose reference is another version of the sheet, and 8 on `hkloco1`); every other has
  a measured length that equals its value at the sheet's true scale. They are values that a sheet
  repeats, paired with another span of the same length than the reference's rebuild chose, and values
  the reference's own rebuild left unexplained (`ec01`: 11 PDF-only, among them 1830 at 18.27 mm and 65
  at 0.64 mm on a 1:100 sheet). Both are right in value; which text goes with which of two equal spans
  is the pairing's ambiguity, and is where a wrong dimension can hide that this check does not find.
- **The reference only (1,175)** is mostly sheets where the DXF holds more than the PDF printed (`es05`
  has 165 dimensions in its DXF and 56 on the page), as in the geometry comparison.
- **Against Jw_cad's flags** (the 15 JWW pairs, where SwiftJWW's `recoveringDimensions()` needs no
  inference): 236 dimensions, and the PDF finds the text of **232** of them.
- 68 of the 321 sheets agree with the reference exactly (no moved, PDF only or reference only).

### Numbers

A Jw_cad PDF writes `1,829` for 1829. Left to the geometry (`numbers: nil`, the default), the reading
holds while the scale is not in doubt; told (`numbers: .commaSeparatesThousands`) it holds always.
With it, `tr-pc2` (where the geometry preferred 20:1, every value read a thousand times smaller)
finds 1:50, 312 sheets are at the fit's scale, and 9 more dimensions match. It is a property of the
writer, so it is an option and not guessed: of three TECS PDFs checked, the producer string says
Acrobat PDFWriter or Distiller, not Jw_cad.

### The scale range

On the TECS sheets a scale of 1:336, 1:340, 1:490, 1:573 or 1:673 was found for five sheets (`dt44`,
`dt44a`, `dt18`, `c5000x`, `dt22c`), each on 3 to 9 values and some with none contradicting; all five
were wrong (the sheets are at 1:30 and 1:80). The lengths are short (1 to 7 mm), and at a large scale
the tolerance (a few percent of the text height, times the scale) is a few percent of the value, so
values agree by chance. A scale outside 10:1 to 1:300 (`DimensionOptions.scaleRange`) is not used and
its values are listed as not explained. On the TECS pairs this removes 40 dimensions, on six sheets (the
five, and `tr-pc2` at 20:1), all at a scale that is not the sheet's, and changes nothing else.

The true scale may be behind the wrong one. Told 1:30 (`--scale 30 --numbers thousands`), `dt18`, `dt22c`, `dt44` and
`dt44a` give 8, 5, 5 and 6 dimensions. But the data do not say it: on `dt18` 1:30 explains 8 of the 9
values and 1:300, inside the range, explains 7 by chance. Trying the usual scales within the range and
taking one only if it explains twice as many as any other was built and gave none of these four, so it
was left out: a scale is given, not guessed.

### Views

`Views.swift` found 1 to 54 views a sheet. Each is asked for a scale of its own. Applying it (replacing
the sheet's scale in that view) was measured against not applying it on the TECS pairs:

| a view's own scale is applied when | sheets flagged | sheets at the fit's scale | dimensions at another scale than the fit's |
|---|---|---|---|
| never (the sheet's scale throughout) | 0 | 311 | 51 |
| it has 8 values and 85 percent of the voters | 2 | 310 | 59 |
| it has 4 values and two thirds of the voters | 8 | 305 | 78 |

(These runs had no scale range, so the first row has the 40 dimensions above in it.) Of the eight at
the lower bar, five were wrong (`c10`, `en56`, `es04`, `es05`, `tmf1`), one right (`hkloco1`, where 1:10
against the sheet's 1:9.85 matched two more dimensions) and two changed no dimension (`i_futou`,
`tr-pc1`); on a ninth (`ps11`) the sheet found no scale and a view found 1:20 on 4 values, which was
right. TECS sheets have one scale, so a disagreement is almost always a coincidence of few values;
the one TECS JWW with two layer groups (`h15a`, 1:50 and 1:10) gives the same 8 dimensions at 1:50
either way. So views report and do not apply: a view whose own values favour another scale, by more
than 10 percent, on 6 values and 80 percent of the voters, has it as `alternative` with the dimensions
it would give, and the result carries a `scalesDisagree` warning. On the final build one TECS sheet is
flagged (`es04`). A sheet with genuinely different scales in different views is not among those
measured, so how well this finds one is not known: the hand-built sheets in the tests are the only
evidence that it can.

### Arrowheads

The corpus PDFs that draw arrowheads as filled triangles are the Fowler, McMaster and UK sheets. The
Jw_cad PDFs have no filled-only paths: their end marks are small diamonds, stroked and filled, and so
already in `drawing()`. Adding the tip of every arrowhead as an end mark changed the scale found on 6 of
the 18 Fowler sheets that have one (2:1 became 1.94:1, 2.07:1 and 1.98:1; 1.3:1 became 1.91:1; 1.99:1
became 2.01:1; and one sheet lost its scale) and dimensions fell from 947 to 928 on the 47 PDFs in
`PDFs/`. A tip beside an extension line says nothing new, and gives the rebuild more spans to explain a
value by chance. Giving SwiftDXF the whole triangle instead was worse: it takes the middle of a fat
dart (a Fowler arrowhead is 3.6 by 2.4 points, not narrow enough to be an arrow to it) as the end, and
`Watergauge` gained 33 dimensions at 1:6.72 measuring 0.4 to 1.3 mm.

So a tip is the corner between the two long sides of a narrow triangle, and is added only where no
piece that crosses the dimension line passes within 0.5 mm of it. With that, the results on all 47 PDFs
are identical to using no arrowheads: most tips are beside another piece, and the few that are not
changed no dimension. That arrowheads end a dimension line that nothing else ends is shown on
hand-built sheets only (`DimensionTests.arrowheads`); no corpus file has one.

### Across the other corpus PDFs

There is no paired drawing for these, so the scale is judged by whether it is round.

| set | pages | with dimensions and a scale | notes |
|---|---|---|---|
| `d51498/` (Jw_cad sheets) | 45 | 45 | 2,071 dimensions; 1:100 (33), 1:80 (10), 1:50 (2) |
| `PDFs/` Fowler (DraftingCAD, mm) | 27 | 18 | 16 of the 18 at 1:1, 2:1 or 4:1 (within 2.5%); 1.3:1 and 2.62:1 are not round; 9 give none |
| `PDFs/` McMaster (SolidWorks) | 5 | 4 | 1:2.46, 1:2.92, 1:8.76, 1.03:1 (scaled to fit the page); the fifth has inch values, which are listed |
| `PDFs/` the rest (UK, ODA, Jw_cad) | 15 | 9 | the 2120 at 1:80; the others 1:1.75, 2.53:1, 1:1.51, 1:3.79, 1:1.33, 1.14:1, 1:1.67, not round |
| `railway-components/` | 13 | 6 | the TECS copies, 1:80 and 1:100; the rest are catalogues, scans or have no text |
| `railway/`, `simple/`, `simple_drawing_examples/` | 24 | 0 | no value text, or no dimension line beside it |

82 of the 129 PDFs outside the TECS pairs give dimensions and a scale. The Jw_cad sheets give round
scales every time and the Fowler sheets in 16 of 18; the others are not 1:N and cannot be judged without
a paired drawing. On a sheet drawn as shapes with invisible text over it (`TS.pdf`, `repw618j.pdf`) or
with no text (`Repw604s.pdf`) there is nothing to rebuild from: the dimension lines are shapes the
interpreter does not see as lines.

### Value text and units

SwiftDXF's reading is used as it is: decimals and thousands separators (a comma or a point read as the
geometry bears out, or as `numbers` says), a diameter or radius symbol (`⌀`, `Ø`, `φ`, `R`), full-width
digits, a trailing `mm`, and only the text before a tolerance stack. Angles, other units (`in`, `ft`,
`"`), several numbers in one text (`33mm±0.02`, `80+0.1`) and numbers that are not read (`1.2.3`) are
not rebuilt, and are warnings with the reason. On the 460 TECS pages 2,768 values are not explained:
2,205 `noMatch` (notes, quantities, and the diameters and radii below), 455 `severalNumbers`, 63
`noScale`, 17 `unreadable`, 14 `unit` and 14 `angular`; and 106 radius symbols sit on a straight
dimension, which is rebuilt and warned (`symbolDisagrees`). There are no feet and inches in the corpus
(the only inch values are McMaster's `0.5in`, listed as a unit), so none are supported.

A diameter or radius needs a circle or an arc, which `drawing()` gives as degree-3 splines until arc
recovery lands (Next item 2). Until then `φ860` and `R40` are rebuilt, where a straight span of that
length is there, as straight dimensions.

### Time

0.1 s a sheet for the sheet's scale and twice that with the views (the 460 TECS pages: 45 s and 92 s in
a release build).

## What was not verified

- Dimensions of any PDF outside the TECS pairs: only counts, and whether the scale is round.
- That a text is paired with the right one of two equal spans. The pairs check the value against the
  geometry and the position against the reference's rebuild, not against a person's reading.
- Sheets with different scales in different views: none among those measured has dimensions at a
  second scale.
- The 131 pairs that were not compared (the bitmaps and the PDF that does not open).
- Arrowheads that are the only end of a dimension line, on a real file.
- Diameter and radius dimensions from a PDF (they need circles and arcs).
- The pages after the first of a multi-page PDF; `pdfprobe` reads the first.
- iOS, tvOS and visionOS were built, not run.
- Whether a better scale hides behind a wrong one. The range is applied after SwiftDXF has picked the
  scale that explains most values, and its rebuild has no option to search only within a range, so a
  wrong winner above 1:300 leaves a sheet with none (the four `dt` sheets, above).

## For the maintainer

- **Recovered, not stored.** SwiftDXF 0.6.0 already has the mark: `Dimension.rebuilt` (the pieces and
  the scale), set by `rebuildingDimensions()` and `nil` for a dimension a file holds. This package uses
  it and invents nothing. SwiftJWW's recovered dimensions are told apart through its report instead
  (`DXFWriter` gives the handles in `recoveredDimensions`), so OCCTSwiftIO#67 and #72 can make the two
  routes agree by setting `rebuilt` from that report, or by running SwiftDXF's rebuild on the JWW's DXF.
- **How OCCTSwiftIO would consume it.** For `.pdf`: read the page, take `drawing()` as for any format,
  and under the same opt-in as OCCTSwiftIO#72 call
  `recoveringDimensions(PDF.DimensionOptions(numbers: ...))`. `recovery.rebuild` is a SwiftDXF
  `DimensionRebuild`, the type a DXF or DWG export gives, so one consumer serves all three: its
  dimensions are marked, its `scales` is the sheet's with the supporting and contradicting counts, and
  its `warnings` are the unexplained values and `scalesDisagree`. `recovery.scale` is the scale to
  offer for the geometry to be read at full size (the paper's millimetres times it); it is for the user
  to accept, and a `nil` scale, or a view with an `alternative`, is the case for asking.
- **Decisions taken here that the maintainer may want otherwise:** views report and do not apply (the
  table above); a scale outside 10:1 to 1:300 is not used; `numbers` is not guessed from the writer;
  the arrowhead rule.
