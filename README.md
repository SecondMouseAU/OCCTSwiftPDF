# OCCTSwiftPDF

[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

Reads **vector PDF drawings** into `DXF.Drawing`, the drawing model of
[SwiftDXF](https://github.com/SecondMouseAU/SwiftDXF), the same model that DXF, DWG
([SwiftDWG](https://github.com/SecondMouseAU/SwiftDWG)) and JWW
([SwiftJWW](https://github.com/SecondMouseAU/SwiftJWW)) drawings are read into. OCCTSwiftIO's
`DrawingLoader` is meant to read PDFs through it, as it reads the other formats.

It uses Apple's frameworks only: CoreGraphics' PDF scanner for the drawing operations (paths,
transforms, text placement, marked content), the package's own font decoding for the text, and
PDFKit as a cross-check on that decoding and a fallback where it has no characters. No third-party
PDF library is linked.

It builds for macOS, iOS, visionOS and tvOS, as OCCTSwiftIO does. PDFKit is not used on tvOS (older
SDKs lack it, and guarding by platform keeps the result the same whichever Xcode builds it), so
there the cross-check is left out and each text run keeps what the package's own decoding read,
which for a font with no usable encoding can be missing or a guess. The comparison tooling
(`PDF.readReference`) and `pdfprobe` are macOS only.

## Status

**Spike.** The question it answers is whether Apple's frameworks are enough to read the vector
PDFs that CAD programs produce, or whether PDFium is needed. The results are in
[`okf/experiments/option-1-spike.md`](okf/experiments/option-1-spike.md).

What it does: interprets each page (paths, transforms, Form XObjects, layers, clipping), decodes
text with its own font decoding and checks it against PDFKit, joins text shown a character at a
time into lines, says whether each page is vector, raster or mixed, and turns a page into a
`DXF.Drawing` in millimetres with an identity on every entity.

Circles and arcs are recovered on request (`fittedDrawing()` below): `drawing()` leaves curves as
splines. Not built yet, on purpose: dimension rebuilding, scale inference, reading text drawn as
shapes, and the wiring into OCCTSwiftIO.

## Use

```swift
import OCCTSwiftPDF

let document = try PDF.read(contentsOf: url)
for page in document.pages where page.kind == .vector {
    let drawing = page.drawing()   // DXF.Drawing, millimetres on the sheet
}

// A run of curves, or of short lines, that is one circle or arc becomes that circle or arc, with
// the radius fitted over the whole run and the residual reported, tagged FITTED.
let fitted = page.fittedDrawing()
for fit in fitted.fits { print(fit.shape, fit.radius, fit.maxResidual) }
```

## Command line

```bash
swift run pdfprobe [--detail] <file-or-folder>...   # what each PDF is made of
swift run pdfprobe compare <pdf> <dxf-or-zip>         # a PDF against the DXF of the same drawing
swift run pdfprobe pairs <folder>                     # every <name>.pdf beside <name>_dxf.zip, or _jww.zip
swift run pdfprobe debug-text <pdf> <text>            # where this reader and PDFKit put a text
swift run pdfprobe arcs [--detail] <file-or-folder>... # circles and arcs recovered, by producer
swift run pdfprobe arc-pairs [--detail] <folder>      # the same against each PDF's DXF, by coordinates
swift run pdfprobe digest <file-or-folder>...         # a hash of each page's drawing(), to compare runs
```

`arcs` and `arc-pairs` take the options of `PDF.ArcFitting` as `--tolerance`, `--relative`,
`--line-tolerance`, `--min-sweep`, `--max-step`, `--min-lines` and `--max-ratio`; `arc-pairs` also
`--bound <mm>` (how near a reference circle must be, on the paper, to match) and `--table <file>`
(one row per fit), and `PDFPROBE_PLACEMENTS=<file>` keeps the reference placements between runs.

`compare` and `pairs` take `--exclude-layer <name>` (repeatable) to leave a DXF layer out, such as
Jw_cad's auxiliary lines, which are never printed: the TECS figures in the experiment page come
from `pdfprobe pairs --exclude-layer ADD_LINE <tecs-pairs folder>`. A zip must hold exactly one
entry, a DXF or a JWW. A JWW (`<name>_jww.zip` or `.lzh`, used where the DXF is missing) is read by
SwiftJWW at full size, without Jw_cad's auxiliary lines, which are never printed.

## License

LGPL-2.1, like OCCTSwiftIO, which is meant to read PDFs through this package. The library links
SwiftDXF (MIT) and Apple's system frameworks (CoreGraphics, PDFKit) and nothing else; the `pdfprobe`
tool also links SwiftJWW (MIT). No third-party code is copied into it, and no third-party drawings
are committed.
