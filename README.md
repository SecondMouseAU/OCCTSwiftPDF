# OCCTSwiftPDF

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

Not built yet, on purpose: arc and circle recovery from curves and runs of short lines, dimension
rebuilding, scale inference, and the wiring into OCCTSwiftIO.

## Command line

```bash
swift run pdfprobe <file-or-folder>...
```

prints, for each PDF, whether its pages are vector, raster (scanned) or mixed, and what they are
made of.
