import Testing

@testable import OCCTSwiftPDF

@Suite("Package")
struct PackageTests {
    @Test("the drawing model is re-exported")
    func drawingModel() {
        let drawing = DXF.Drawing()
        #expect(drawing.entities.isEmpty)
    }
}
