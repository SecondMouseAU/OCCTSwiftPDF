---
type: repo
title: OCCTSwiftPDF
resource: https://github.com/SecondMouseAU/OCCTSwiftPDF
tags: [pdf, vector, 2d, import, drawing, swift]
description: Reader for vector PDF drawings into the SwiftDXF drawing model, on Apple's frameworks only. A spike today.
timestamp: 2026-11-18
---

# OCCTSwiftPDF

A reader for **vector PDF drawings**, returning the `DXF.Drawing` model of SwiftDXF so that a
drawing is read the same way whatever its format. It is built on Apple's CoreGraphics PDF scanner
and PDFKit, with no third-party PDF library.

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on:** SwiftDXF (the drawing model); SwiftJWW for the `pdfprobe` tool only
- **Feeds products:** PDF import for OCCTSwiftIO's `DrawingLoader`, and through it the Drawings
  Toolbox (OCCTDesignLoop). Phase 4 of the ecosystem plan `okf/plans/drawings-toolbox.md`.
- **Visibility:** public, LGPL-2.1 (as OCCTSwiftIO).

## Components

See [`components/`](components/index.md) for the public surface.

## References

See [`references/`](references/index.md) for the PDF format, the research behind the design, and
the corpus results are checked against.

## Experiments

- [Option 1 spike: Apple's frameworks only](experiments/option-1-spike.md)

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
- [Documentation updates are mandatory](policies/docs-current.md)
- [No em-dashes, banned words in prose](policies/writing-style.md)
- [Search before building](policies/search-before-building.md)
- [Code structure](policies/code-structure.md)
- [Issue labels and project-board tracking](policies/issue-tracking.md)
- [Code style](policies/code-style.md)
