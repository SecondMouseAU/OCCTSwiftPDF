// TextRecogniser.swift
// OCCTSwiftPDF
//
// The second step of recovering text drawn as shapes: recognising the text in an image. A seam: the
// rest does not know it is Vision, so the agreement rules can be tested with a recogniser that says
// what the test needs, on any platform.

import CoreGraphics
import Foundation

/// A line of text a recogniser found in an image.
struct RecognisedLine {
    var text: String
    /// From 0 to 1.
    var confidence: Double
    /// The line's corners as fractions of the image's width and height from its lower left:
    /// bottom left, bottom right, top right, top left, as the line reads.
    var corners: [CGPoint]
}

/// Something that reads the text in an image.
protocol TextRecogniser {
    func lines(in image: CGImage) throws -> [RecognisedLine]
}

extension PDF {
    /// A failure of the recogniser, or no recogniser on the platform.
    public enum RecognitionError: Swift.Error, Equatable {
        /// This platform has no Vision framework.
        case unavailable
        /// Vision failed on an image; the message is its own.
        case failed(String)
    }
}
