# CLAUDE.md

Guidance for Claude Code in this repository.

## Read first

- `okf/index.md`: the repo's OKF bundle (components, references, experiments, policies). Read the
  page the task needs, when it needs it.
- The cross-repo plan that sequences this work is `okf/plans/drawings-toolbox.md` in the
  `ecosystem` repo (Phase 4, vector PDF).

## What this package is

A reader for **vector PDF drawings** into `DXF.Drawing`, the SwiftDXF model that DXF, DWG and JWW
are read into, so that OCCTSwiftIO's `DrawingLoader` can read a PDF like any other drawing. It is a
spike today (Option 1 of the research: Apple's frameworks only); see
`okf/experiments/option-1-spike.md`.

## Licence rules (these are not optional)

- This package is LGPL-2.1, as OCCTSwiftIO is. Only permissive or LGPL code may be linked: Apple's
  frameworks, MIT, BSD, Apache-2.0, zlib. Today the library links SwiftDXF (MIT) and Apple's
  frameworks, and `pdfprobe` also links SwiftJWW (MIT).
- **Never link or copy Poppler, Xpdf (GPL) or MuPDF (AGPL).** Their command-line tools
  (`pdftotext`, `pdffonts`, `pdftocairo`) may be run during development to check results; nothing
  may depend on them.
- su-pdfimporter (MIT) may be read as a reference design. Credit any code that follows it.
- The PDFs in the corpus are third-party drawings. They stay out of the repository and are read
  from `PDF_CORPUS` (default `~/Projects/OCCTDesignLoop/drawingfiles`); tests that need them skip
  where it is absent.

## Build and test

```bash
swift build
swift test
swift run pdfprobe <file-or-folder>...
swift-format lint --strict --recursive Sources Tests
swiftlint lint --strict
```

## Conventions

- Swift 6 language mode. Swift Testing (`@Suite` / `@Test` / `#expect`). Never
  `#expect(x != nil); #expect(x!.y)`: use `if let x { #expect(x.y) }`.
- swift-format `--strict`: a doc comment's summary line ends with a period and is followed by a
  blank `///` line.
- No em-dashes and no "honest" or "you're right" in prose (`okf/policies/writing-style.md`).
- Docs ship with the change (`okf/policies/docs-current.md`).
- Analytic, not pixels: correctness is shown against the paired DXF or JWW of the same drawing,
  by coordinates, never by comparing pictures.
- CI runs on GitHub's hosted `macos-15` runners, which are free for this public repo.
