# OCCTSwiftPDF

[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

Reads **vector PDF drawings** into `DXF.Drawing`, the drawing model of
[SwiftDXF](https://github.com/SecondMouseAU/SwiftDXF), the same model that DXF, DWG
([SwiftDWG](https://github.com/SecondMouseAU/SwiftDWG)) and JWW
([SwiftJWW](https://github.com/SecondMouseAU/SwiftJWW)) drawings are read into. OCCTSwiftIO's
`DrawingLoader` is meant to read PDFs through it, as it reads the other formats.

It uses Apple's frameworks only: CoreGraphics' PDF scanner for the drawing operations (paths,
transforms, text placement, marked content) and PDFKit for decoded text. No third-party PDF
library is linked.

## Status

**Spike.** The question it answers is whether Apple's frameworks are enough to read the vector
PDFs that CAD programs produce, or whether PDFium is needed. The results are in
[`okf/experiments/option-1-spike.md`](okf/experiments/option-1-spike.md).

What it does: interprets each page (paths, transforms, Form XObjects, layers, clipping), decodes
text with its own font decoding and checks it against PDFKit, joins text shown a character at a
time into lines, says whether each page is vector, raster or mixed, and turns a page into a
`DXF.Drawing` in millimetres with an identity on every entity.

Not built yet, on purpose: arc and circle recovery from curves and runs of short lines, dimension
rebuilding, scale inference, reading text drawn as shapes, and the wiring into OCCTSwiftIO.

## Use

```swift
import OCCTSwiftPDF

let document = try PDF.read(contentsOf: url)
for page in document.pages where page.kind == .vector {
    let drawing = page.drawing()   // DXF.Drawing, millimetres on the sheet
}
```

## Command line

```bash
swift run pdfprobe [--detail] <file-or-folder>...   # what each PDF is made of
swift run pdfprobe compare <pdf> <dxf-or-zip>         # a PDF against the DXF of the same drawing
swift run pdfprobe pairs <folder>                     # every <name>.pdf beside <name>_dxf.zip
swift run pdfprobe debug-text <pdf> <text>            # where this reader and PDFKit put a text
```

`compare` and `pairs` take `--exclude-layer <name>` (repeatable) to leave a DXF layer out, such as
Jw_cad's auxiliary lines, which are never printed: the TECS figures in the experiment page come
from `pdfprobe pairs --exclude-layer ADD_LINE <tecs-pairs folder>`. A zip must hold exactly one
entry, a DXF.

## License

LGPL-2.1, like OCCTSwiftIO, which is meant to read PDFs through this package. It links SwiftDXF
(MIT) and Apple's system frameworks (CoreGraphics, PDFKit) and nothing else; no third-party code is
copied into it, and no third-party drawings are committed.
