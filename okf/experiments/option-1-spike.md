---
type: experiment
title: Option 1 spike, Apple's frameworks only
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [spike, pdf, cgpdfscanner, pdfkit, vector]
description: Whether CoreGraphics' PDF scanner and PDFKit are enough to read CAD-exported vector PDFs into DXF.Drawing, or whether PDFium is needed.
timestamp: 2026-11-18
---

# Option 1 spike: Apple's frameworks only

**Status: planned.**

## Questions

1. Which PDFs in the corpus are vector, raster (scanned) or mixed?
2. Can the scanner's text operations be decoded, by this package's own font decoding or by
   pairing them with PDFKit's decoded characters by position? Which files have text that cannot
   be decoded, or text drawn as geometry?
3. Are PDF layers (optional content) recovered where the file has them?
4. Are Form XObjects (nested drawings) followed, with their transforms?
5. Does the geometry agree with the paired DXF of the same drawing (TECS pairs), by coordinates?

## Out of scope

Arc and circle recovery, dimension rebuilding, scale inference, and the wiring into OCCTSwiftIO.
