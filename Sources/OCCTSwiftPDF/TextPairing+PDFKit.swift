// TextPairing+PDFKit.swift
// OCCTSwiftPDF
//
// Asking PDFKit for each run's characters. PDFKit is not used on tvOS, so there this file is empty
// and a run keeps the text this reader's own font decoding gave it.

#if canImport(PDFKit) && !os(tvOS)
    import CoreGraphics
    import Foundation
    import PDFKit

    extension TextPairing {
        /// Pairs each run with the characters PDFKit finds for it.
        static func pair(_ runs: inout [PDF.TextRun], with page: PDFPage) {
            for index in runs.indices {
                let run = runs[index]
                guard run.width > 0, run.height > 0 else { continue }
                let quarterTurns = run.rotationDeg / 90
                let alongAxis = abs(quarterTurns - quarterTurns.rounded()) < 1.0 / 90
                let selection: PDFSelection?
                if alongAxis {
                    guard let rect = innerRect(run) else { continue }
                    selection = page.selection(for: rect)
                } else {
                    guard let (from, to) = endPoints(run) else { continue }
                    selection = page.selection(from: from, to: to)
                }
                let found = selection?.string?.filter { !$0.isWhitespace && !$0.isNewline }
                guard let found, !found.isEmpty else { continue }
                runs[index].pdfKitText = found
                // PDFKit's characters stand in where this reader has none. For a run along or across
                // the page they also replace guessed ASCII that PDFKit contradicts and a reading with
                // U+FFFD. For an inclined run they never replace this reader's own reading, and fill
                // in only when there are as many of them as the run has character codes.
                let own = run.text?.filter { !$0.isWhitespace }
                let replace: Bool
                if alongAxis {
                    replace =
                        run.text == nil || (run.decoding == .asciiGuess && own != found)
                        || (run.text?.contains("\u{FFFD}") == true && !found.contains("\u{FFFD}"))
                } else {
                    replace = run.text == nil && found.count == run.codeCount
                }
                if replace {
                    runs[index].text = found
                    runs[index].decoding = .pdfKit
                }
            }
        }
    }
#endif
