import Foundation

/// Builds small PDFs by hand, object by object, so a test controls every operator and resource.
struct MiniPDF {
    /// The page's content stream.
    var content: String
    /// The page's resource dictionary, written as PDF source, with `{n}` standing for object `n`
    /// of ``objects`` (counted from 1).
    var resources = "<< >>"
    /// Extra indirect objects, each a complete PDF object body; `{n}` refers to the n-th.
    var objects: [String] = []
    var mediaBox = "[0 0 612 792]"
    var rotate = 0
    /// Entries added to the catalog, such as `/OCProperties << ... >>`.
    var catalogExtra = ""

    /// A stream object with `dictionary` entries (without `<<` `>>`) and `body`.
    static func stream(_ dictionary: String, _ body: String) -> String {
        "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
    }

    func data() -> Data {
        // Objects 1 to 3 are the catalog, the page tree and the page; 4 is the content stream;
        // the extra objects follow from 5.
        let offset = 4
        func resolve(_ text: String) -> String {
            var out = text
            for index in stride(from: objects.count, through: 1, by: -1) {
                out = out.replacingOccurrences(of: "{\(index)}", with: "\(index + offset) 0 R")
            }
            return out
        }
        var bodies = [
            "<< /Type /Catalog /Pages 2 0 R \(resolve(catalogExtra)) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) /Rotate \(rotate) "
                + "/Resources \(resolve(resources)) /Contents 4 0 R >>",
            Self.stream("", content),
        ]
        bodies += objects.map(resolve)
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out += Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out += Data(table.utf8)
        return out
    }

    /// Writes the PDF to a new temporary file and returns its URL.
    func file(_ name: String = "test.pdf") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCCTSwiftPDFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data().write(to: url)
        return url
    }

    /// Helvetica as a standard simple font with no widths, so each character advances half an em.
    static let helvetica = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
}
