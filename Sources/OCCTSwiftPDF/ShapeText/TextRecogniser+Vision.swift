// TextRecogniser+Vision.swift
// OCCTSwiftPDF
//
// Apple Vision's text recognition as a ``TextRecogniser``. Where Vision is not there (it is on every
// platform this package builds for, but a toolchain without it must still build) there is none.

#if canImport(Vision)
    import CoreGraphics
    import Foundation
    import Vision

    /// Held while Vision recognises, so that one request is in flight in the process at a time.
    ///
    /// Requests from several threads at once can deadlock inside Vision's own task queue: the test
    /// suite, run in parallel, stopped dead there.
    private let visionLock = NSLock()

    /// Recognises text with `VNRecognizeTextRequest` at its accurate level, without language
    /// correction (a drawing's text is codes and numbers, which correction would turn into words).
    struct VisionTextRecogniser: TextRecogniser {
        func lines(in image: CGImage) throws -> [RecognisedLine] {
            visionLock.lock()
            defer { visionLock.unlock() }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw PDF.RecognitionError.failed("\(error)")
            }
            return (request.results ?? []).compactMap { observation in
                guard let best = observation.topCandidates(1).first else { return nil }
                return RecognisedLine(
                    text: best.string, confidence: Double(best.confidence),
                    corners: [
                        observation.bottomLeft, observation.bottomRight, observation.topRight,
                        observation.topLeft,
                    ])
            }
        }
    }
#endif
