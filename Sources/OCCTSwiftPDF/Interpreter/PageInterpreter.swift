// PageInterpreter.swift
// OCCTSwiftPDF
//
// Runs a page's content stream through CoreGraphics' scanner and keeps the state the scanner does
// not: the graphics state stack, the current path, the text state, marked content (layers) and
// Form XObjects.

import CoreGraphics
import Foundation

/// Interprets one page.
///
/// Not thread-safe: one interpreter per page, used once.
final class PageInterpreter {
    struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var lineWidth = 1.0
        var dash: [Double] = []
        var stroke = PDF.Colour.black
        var fill = PDF.Colour.black
        var strokeSpace = ColourSpace.gray
        var fillSpace = ColourSpace.gray
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var horizontalScale = 1.0
        var leading = 0.0
        var rise = 0.0
        var font: Font?
        var fontSize = 0.0
        var renderMode = 0
    }

    let pageNumber: Int
    private(set) var paths: [PDF.Path] = []
    private(set) var texts: [PDF.TextRun] = []
    private(set) var images: [PDF.Image] = []
    private(set) var clipPaths = 0
    private(set) var formInvocations = 0
    private(set) var inlineImages = 0
    private(set) var shadings = 0
    private(set) var layersSeen: [String] = []

    private var state = GraphicsState()
    private var stack: [GraphicsState] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var subpaths: [PDF.Subpath] = []
    private var pendingClip = false
    private var operatorIndex = 0
    /// Marked-content layers, innermost last; `nil` for marked content that is not a layer.
    private var layerStack: [String?] = []
    /// While a Form XObject runs, the depths of ``stack`` and ``layerStack`` it started at: its
    /// own `Q` and `EMC` may not pop below them, into the page's saved states and layers.
    private var stackFloor = 0
    private var layerFloor = 0
    private var formStack: [String] = []
    private var formCounts: [String: Int] = [:]
    private var activeForms: Set<Int> = []
    /// The content streams enclosing the one being scanned, outermost first: the page's, then
    /// those of any Form XObjects it is inside.
    private var enclosingStreams: [CGPDFContentStreamRef] = []
    private var fonts: [Int: Font] = [:]
    private let table: CGPDFOperatorTableRef

    static let maximumFormDepth = 16

    init(pageNumber: Int) {
        self.pageNumber = pageNumber
        table = Self.makeTable()
    }

    deinit { CGPDFOperatorTableRelease(table) }

    func run(_ page: CGPDFPage) {
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan(stream)
        CGPDFContentStreamRelease(stream)
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private var currentLayer: String? { layerStack.last(where: { $0 != nil }) ?? nil }

    private var source: PDF.Source {
        PDF.Source(page: pageNumber, operatorIndex: operatorIndex, forms: formStack)
    }

    /// A named resource, looked up in the stream being scanned and then in the streams enclosing
    /// it, since a form without resources of its own uses its parent's.
    private func resource(
        _ category: String, _ name: UnsafePointer<CChar>, in stream: CGPDFContentStreamRef
    )
        -> CGPDFObjectRef?
    {
        if let found = CGPDFContentStreamGetResource(stream, category, name) { return found }
        for outer in enclosingStreams.reversed() {
            if let found = CGPDFContentStreamGetResource(outer, category, name) { return found }
        }
        return nil
    }

    // MARK: graphics state

    fileprivate func tick() { operatorIndex += 1 }

    fileprivate func save() { stack.append(state) }

    fileprivate func restore() {
        guard stack.count > stackFloor, let last = stack.popLast() else { return }
        state = last
    }

    fileprivate func concat(_ scanner: CGPDFScannerRef) {
        guard let m = Self.popMatrix(scanner) else { return }
        state.ctm = m.concatenating(state.ctm)
    }

    fileprivate func setLineWidth(_ scanner: CGPDFScannerRef) {
        if let width = Self.popNumbers(scanner, 1) { state.lineWidth = width[0] }
    }

    fileprivate func setDash(_ scanner: CGPDFScannerRef) {
        var phase: CGPDFReal = 0
        var array: CGPDFArrayRef?
        guard CGPDFScannerPopNumber(scanner, &phase), CGPDFScannerPopArray(scanner, &array),
            let array
        else { return }
        state.dash = PDFObjects.numbers(array)
    }

    /// The colour spaces this reader turns into a colour; anything else draws black.
    enum ColourSpace {
        case gray, rgb, cmyk
        /// One tint, from no ink (0) to full ink (1), drawn as gray.
        case separation
        /// Indexed, pattern, DeviceN or an unknown space.
        case other
    }

    /// `G`, `g`, `RG`, `rg`, `K`, `k`: a fixed number of components, which also set the space.
    fileprivate func setDeviceColour(_ scanner: CGPDFScannerRef, _ space: ColourSpace, stroke: Bool)
    {
        if stroke { state.strokeSpace = space } else { state.fillSpace = space }
        setColour(scanner, stroke: stroke)
    }

    /// Sets the colour space for `SC`, `SCN`, `sc` and `scn` (`CS`, `cs`).
    ///
    /// The space is named, or found through the `ColorSpace` resources. The colour becomes the
    /// space's initial colour, black.
    fileprivate func setColourSpace(_ scanner: CGPDFScannerRef, stroke: Bool) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let space: ColourSpace
        switch String(cString: name) {
        case "DeviceGray", "G", "CalGray": space = .gray
        case "DeviceRGB", "RGB", "CalRGB": space = .rgb
        case "DeviceCMYK", "CMYK": space = .cmyk
        default:
            let stream = CGPDFScannerGetContentStream(scanner)
            space = resource("ColorSpace", name, in: stream).map(Self.colourSpace) ?? .other
        }
        if stroke {
            state.strokeSpace = space
            state.stroke = .black
        } else {
            state.fillSpace = space
            state.fill = .black
        }
    }

    /// A colour space resource: an array whose first entry names the family.
    static func colourSpace(_ object: CGPDFObjectRef) -> ColourSpace {
        var array: CGPDFArrayRef?
        var family: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(object, .array, &array), let array,
            CGPDFArrayGetName(array, 0, &family), let family
        else { return .other }
        switch String(cString: family) {
        case "CalGray": return .gray
        case "CalRGB": return .rgb
        case "Separation": return .separation
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream,
                let dict = CGPDFStreamGetDictionary(stream)
            else { return .other }
            switch PDFObjects.integer(dict, "N") {
            case 1: return .gray
            case 3: return .rgb
            case 4: return .cmyk
            default: return .other
            }
        default: return .other
        }
    }

    /// The colour from the current space's components.
    ///
    /// Operands are popped as objects and their type checked: `CGPDFScannerPopName` removes the
    /// top operand even when it is a number. A pattern name on top of `scn` is passed over.
    fileprivate func setColour(_ scanner: CGPDFScannerRef, stroke: Bool) {
        let space = stroke ? state.strokeSpace : state.fillSpace
        let wanted: Int
        switch space {
        case .gray, .separation: wanted = 1
        case .rgb: wanted = 3
        case .cmyk: wanted = 4
        case .other:
            if stroke { state.stroke = .black } else { state.fill = .black }
            return
        }
        var values: [Double] = []
        var object: CGPDFObjectRef?
        while values.count < wanted, CGPDFScannerPopObject(scanner, &object), let object {
            var value: CGPDFReal = 0
            if CGPDFObjectGetValue(object, .real, &value) {
                values.insert(Double(value), at: 0)
            } else if !values.isEmpty {
                return
            }
        }
        guard values.count == wanted else { return }
        let colour: PDF.Colour
        switch space {
        case .gray: colour = PDF.Colour(red: values[0], green: values[0], blue: values[0])
        case .separation:
            let gray = 1 - values[0]
            colour = PDF.Colour(red: gray, green: gray, blue: gray)
        case .rgb: colour = PDF.Colour(red: values[0], green: values[1], blue: values[2])
        case .cmyk:
            let k = values[3]
            colour = PDF.Colour(
                red: (1 - values[0]) * (1 - k), green: (1 - values[1]) * (1 - k),
                blue: (1 - values[2]) * (1 - k))
        case .other: return
        }
        if stroke { state.stroke = colour } else { state.fill = colour }
    }

    // MARK: paths

    private func transformed(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x, y: y).applying(state.ctm)
    }

    fileprivate func moveTo(_ scanner: CGPDFScannerRef) {
        guard let p = Self.popNumbers(scanner, 2) else { return }
        subpaths.append(PDF.Subpath(start: transformed(p[0], p[1])))
    }

    fileprivate func lineTo(_ scanner: CGPDFScannerRef) {
        guard let p = Self.popNumbers(scanner, 2) else { return }
        append(.line(to: transformed(p[0], p[1])))
    }

    /// `c`, `v` (first control point is the current point) or `y` (second is the end point).
    fileprivate func curveTo(_ scanner: CGPDFScannerRef, kind: Character) {
        let count = kind == "c" ? 6 : 4
        guard let p = Self.popNumbers(scanner, count), let current = currentPoint else { return }
        switch kind {
        case "c":
            append(
                .curve(
                    control1: transformed(p[0], p[1]), control2: transformed(p[2], p[3]),
                    to: transformed(p[4], p[5])))
        case "v":
            append(
                .curve(
                    control1: current, control2: transformed(p[0], p[1]),
                    to: transformed(p[2], p[3])))
        default:
            let end = transformed(p[2], p[3])
            append(.curve(control1: transformed(p[0], p[1]), control2: end, to: end))
        }
    }

    fileprivate func rectangle(_ scanner: CGPDFScannerRef) {
        guard let r = Self.popNumbers(scanner, 4) else { return }
        let (x, y, w, h) = (r[0], r[1], r[2], r[3])
        subpaths.append(
            PDF.Subpath(
                start: transformed(x, y),
                segments: [
                    .line(to: transformed(x + w, y)), .line(to: transformed(x + w, y + h)),
                    .line(to: transformed(x, y + h)), .line(to: transformed(x, y)),
                ],
                isClosed: true))
    }

    fileprivate func closePath() {
        guard var last = subpaths.popLast() else { return }
        let end = last.segments.last?.end ?? last.start
        if end != last.start { last.segments.append(.line(to: last.start)) }
        last.isClosed = true
        subpaths.append(last)
    }

    private var currentPoint: CGPoint? {
        guard let last = subpaths.last else { return nil }
        return last.segments.last?.end ?? last.start
    }

    private func append(_ segment: PDF.Segment) {
        if subpaths.isEmpty { subpaths.append(PDF.Subpath(start: .zero)) }
        subpaths[subpaths.count - 1].segments.append(segment)
    }

    fileprivate func markClip() { pendingClip = true }

    /// Paint and end the current path; `paint` is `nil` for `n`, which only ends it.
    fileprivate func paint(_ paint: PDF.Paint?, close: Bool = false, evenOdd: Bool = false) {
        if close { closePath() }
        let painted = subpaths.filter { !$0.segments.isEmpty }
        if let paint, !painted.isEmpty {
            let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
            paths.append(
                PDF.Path(
                    subpaths: painted, paint: paint, evenOdd: evenOdd,
                    lineWidth: state.lineWidth * scale, dash: state.dash.map { $0 * scale },
                    strokeColour: state.stroke, fillColour: state.fill, layer: currentLayer,
                    source: source))
            noteLayer()
        } else if pendingClip {
            clipPaths += 1
        }
        subpaths = []
        pendingClip = false
    }

    private func noteLayer() {
        if let layer = currentLayer, !layersSeen.contains(layer) { layersSeen.append(layer) }
    }

    // MARK: text

    fileprivate func beginText() {
        textMatrix = .identity
        lineMatrix = .identity
    }

    fileprivate func setFont(_ scanner: CGPDFScannerRef) {
        var size: CGPDFReal = 0
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name),
            let name
        else { return }
        state.fontSize = Double(size)
        let stream = CGPDFScannerGetContentStream(scanner)
        var dict: CGPDFDictionaryRef?
        guard let object = resource("Font", name, in: stream),
            CGPDFObjectGetValue(object, .dictionary, &dict), let dict
        else {
            state.font = nil
            return
        }
        if let known = fonts[Self.key(dict)] {
            state.font = known
        } else {
            let font = Font(dict)
            fonts[Self.key(dict)] = font
            state.font = font
        }
    }

    fileprivate func setTextState(_ scanner: CGPDFScannerRef, _ op: String) {
        guard let v = Self.popNumbers(scanner, 1)?[0] else { return }
        switch op {
        case "Tc": state.charSpacing = v
        case "Tw": state.wordSpacing = v
        case "Tz": state.horizontalScale = v / 100
        case "TL": state.leading = v
        case "Ts": state.rise = v
        case "Tr": state.renderMode = Int(v)
        default: break
        }
    }

    fileprivate func moveText(_ scanner: CGPDFScannerRef, setLeading: Bool) {
        guard let t = Self.popNumbers(scanner, 2) else { return }
        if setLeading { state.leading = -t[1] }
        nextLine(t[0], t[1])
    }

    fileprivate func nextLine(_ tx: Double, _ ty: Double) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    fileprivate func setTextMatrix(_ scanner: CGPDFScannerRef) {
        guard let m = Self.popMatrix(scanner) else { return }
        textMatrix = m
        lineMatrix = m
    }

    fileprivate func showString(_ scanner: CGPDFScannerRef) {
        var string: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &string), let string else { return }
        show([.bytes(PDFObjects.bytes(string))])
    }

    fileprivate func showArray(_ scanner: CGPDFScannerRef) {
        var array: CGPDFArrayRef?
        guard CGPDFScannerPopArray(scanner, &array), let array else { return }
        var parts: [ShowPart] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var string: CGPDFStringRef?
            var number: CGPDFReal = 0
            if CGPDFArrayGetString(array, index, &string), let string {
                parts.append(.bytes(PDFObjects.bytes(string)))
            } else if CGPDFArrayGetNumber(array, index, &number) {
                parts.append(.adjust(Double(number)))
            }
        }
        show(parts)
    }

    /// `'` and `"`: move to the next line, then show.
    fileprivate func nextLineAndShow(_ scanner: CGPDFScannerRef, spacing: Bool) {
        var string: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &string), let string else { return }
        if spacing, let s = Self.popNumbers(scanner, 2) {
            state.wordSpacing = s[0]
            state.charSpacing = s[1]
        }
        nextLine(0, -state.leading)
        show([.bytes(PDFObjects.bytes(string))])
    }

    enum ShowPart {
        case bytes([UInt8])
        /// A `TJ` number: thousandths of a text space unit, subtracted from the advance.
        case adjust(Double)
    }

    private func show(_ parts: [ShowPart]) {
        guard let font = state.font else { return }
        let size = state.fontSize
        let scale = state.horizontalScale
        let start = textMatrix
        var allBytes: [UInt8] = []
        for part in parts {
            switch part {
            case .adjust(let thousandths):
                advance(-thousandths / 1000 * size * scale)
            case .bytes(let bytes):
                allBytes += bytes
                for (code, length) in font.codes(bytes) {
                    var tx = font.advance(of: code, length: length) * size + state.charSpacing
                    if length == 1 && code == 32 { tx += state.wordSpacing }
                    advance(tx * scale)
                }
            }
        }
        guard !allBytes.isEmpty else { return }
        let toPage = start.concatenating(state.ctm)
        let endToPage = textMatrix.concatenating(state.ctm)
        let origin = CGPoint(x: 0, y: state.rise).applying(toPage)
        let end = CGPoint(x: 0, y: state.rise).applying(endToPage)
        let top = CGPoint(x: 0, y: state.rise + size).applying(toPage)
        let up = CGPoint(x: top.x - origin.x, y: top.y - origin.y)
        let along = CGPoint(x: end.x - origin.x, y: end.y - origin.y)
        let width = hypot(along.x, along.y)
        let axis = width > 1e-9 ? along : CGPoint(x: toPage.a, y: toPage.b)
        let decoded = font.decode(allBytes)
        texts.append(
            PDF.TextRun(
                codes: allBytes, codeCount: font.codes(allBytes).count, text: decoded.text,
                decoding: decoded.decoding,
                ownText: decoded.text, pdfKitText: nil, origin: origin,
                rotationDeg: atan2(axis.y, axis.x) * 180 / .pi, height: hypot(up.x, up.y),
                width: width,
                quad: [
                    origin, end, CGPoint(x: end.x + up.x, y: end.y + up.y),
                    CGPoint(x: origin.x + up.x, y: origin.y + up.y),
                ],
                fontName: font.name, fontSubtype: font.subtype,
                isInvisible: state.renderMode == 3 || state.renderMode == 7,
                layer: currentLayer, source: source))
        noteLayer()
    }

    private func advance(_ tx: Double) {
        textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
    }

    // MARK: marked content (layers)

    fileprivate func beginMarkedContent(_ scanner: CGPDFScannerRef, withProperties: Bool) {
        var layer: String?
        if withProperties {
            var properties: CGPDFObjectRef?
            var tag: UnsafePointer<CChar>?
            guard CGPDFScannerPopObject(scanner, &properties),
                CGPDFScannerPopName(scanner, &tag), let tag
            else {
                layerStack.append(nil)
                return
            }
            if String(cString: tag) == "OC", let properties {
                layer = layerName(properties, stream: CGPDFScannerGetContentStream(scanner))
            }
        } else {
            var tag: UnsafePointer<CChar>?
            _ = CGPDFScannerPopName(scanner, &tag)
        }
        layerStack.append(layer)
    }

    fileprivate func endMarkedContent() {
        if layerStack.count > layerFloor { layerStack.removeLast() }
    }

    /// The name of the layer a `BDC /OC` operand names, directly or through `Properties`.
    private func layerName(_ object: CGPDFObjectRef, stream: CGPDFContentStreamRef) -> String? {
        var dict: CGPDFDictionaryRef?
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name,
            let resource = resource("Properties", name, in: stream)
        {
            _ = CGPDFObjectGetValue(resource, .dictionary, &dict)
        } else {
            _ = CGPDFObjectGetValue(object, .dictionary, &dict)
        }
        guard let dict else { return nil }
        return Self.optionalContentName(dict)
    }

    /// The name of an optional content group, or of the first group a membership dictionary uses.
    static func optionalContentName(_ dict: CGPDFDictionaryRef) -> String? {
        if PDFObjects.name(dict, "Type") == "OCMD" {
            if let group = PDFObjects.dictionary(dict, "OCGs") {
                return PDFObjects.text(group, "Name")
            }
            if let groups = PDFObjects.array(dict, "OCGs") {
                var first: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(groups, 0, &first), let first {
                    return PDFObjects.text(first, "Name")
                }
            }
            return nil
        }
        return PDFObjects.text(dict, "Name")
    }

    // MARK: XObjects

    fileprivate func doXObject(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let stream = CGPDFScannerGetContentStream(scanner)
        var xobject: CGPDFStreamRef?
        guard let object = resource("XObject", name, in: stream),
            CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
            let dict = CGPDFStreamGetDictionary(xobject)
        else { return }
        switch PDFObjects.name(dict, "Subtype") {
        case "Image":
            let corners = [
                CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
            ]
            .map { $0.applying(state.ctm) }
            images.append(
                PDF.Image(
                    corners: corners, pixelWidth: PDFObjects.integer(dict, "Width") ?? 0,
                    pixelHeight: PDFObjects.integer(dict, "Height") ?? 0,
                    area: Self.polygonArea(corners), source: source))
        case "Form":
            runForm(xobject, dict: dict, name: String(cString: name), parent: stream)
        default:
            break
        }
    }

    private func runForm(
        _ xobject: CGPDFStreamRef, dict: CGPDFDictionaryRef, name: String,
        parent: CGPDFContentStreamRef
    ) {
        guard formStack.count < Self.maximumFormDepth, !activeForms.contains(Self.key(xobject))
        else { return }
        formInvocations += 1
        formCounts[name, default: 0] += 1
        // The form's content may leave its `q`, `Q`, `BDC` and `EMC` unbalanced; whatever it does,
        // the page goes on from exactly the state and depths it had before the form.
        let savedState = state
        let stackDepth = stack.count
        let layerDepth = layerStack.count
        let outerFloors = (stackFloor, layerFloor)
        stackFloor = stackDepth
        let savedSubpaths = subpaths
        let savedTextMatrix = textMatrix
        let savedLineMatrix = lineMatrix
        if let array = PDFObjects.array(dict, "Matrix"), let matrix = PDFObjects.matrix(array) {
            state.ctm = matrix.concatenating(state.ctm)
        }
        // A form can belong to a layer itself, through its `/OC` entry.
        var formLayer: String?
        if let oc = PDFObjects.dictionary(dict, "OC") { formLayer = Self.optionalContentName(oc) }
        layerStack.append(formLayer)
        layerFloor = layerStack.count
        formStack.append("\(name)#\(formCounts[name] ?? 1)")
        activeForms.insert(Self.key(xobject))
        subpaths = []
        // Without its own resources a form uses its parent's; the form's dictionary stands in, and
        // lookups that miss it go on to the parent stream.
        let resources = PDFObjects.dictionary(dict, "Resources") ?? dict
        let content = CGPDFContentStreamCreateWithStream(xobject, resources, parent)
        enclosingStreams.append(parent)
        scan(content)
        enclosingStreams.removeLast()
        CGPDFContentStreamRelease(content)
        activeForms.remove(Self.key(xobject))
        formStack.removeLast()
        if stack.count > stackDepth { stack.removeSubrange(stackDepth...) }
        if layerStack.count > layerDepth { layerStack.removeSubrange(layerDepth...) }
        (stackFloor, layerFloor) = outerFloors
        state = savedState
        subpaths = savedSubpaths
        textMatrix = savedTextMatrix
        lineMatrix = savedLineMatrix
    }

    /// An inline image (`BI` ... `ID` ... `EI`) fills the unit square under the current transform,
    /// like an image XObject, so it counts towards the page's image coverage.
    fileprivate func inlineImage() {
        inlineImages += 1
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        ]
        .map { $0.applying(state.ctm) }
        images.append(
            PDF.Image(
                corners: corners, pixelWidth: 0, pixelHeight: 0, area: Self.polygonArea(corners),
                source: source))
    }
    fileprivate func countShading() { shadings += 1 }

    // MARK: operands

    /// `count` numbers, in the order they were written.
    static func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double]? {
        var values = [Double](repeating: 0, count: count)
        var value: CGPDFReal = 0
        for index in stride(from: count - 1, through: 0, by: -1) {
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[index] = Double(value)
        }
        return values
    }

    static func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
        guard let m = popNumbers(scanner, 6) else { return nil }
        return CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }

    static func polygonArea(_ points: [CGPoint]) -> Double {
        var sum = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

// MARK: the operator table

/// The interpreter a callback's `info` points to, with the operator counted.
///
/// A file-level function, so the callbacks capture nothing and can be C function pointers.
private func interpreter(_ info: UnsafeMutableRawPointer?) -> PageInterpreter {
    let interpreter = Unmanaged<PageInterpreter>.fromOpaque(info!).takeUnretainedValue()
    interpreter.tick()
    return interpreter
}

extension PageInterpreter {
    // One callback per operator: a C callback cannot capture which operator it was registered for.
    // swiftlint:disable:next function_body_length
    static func makeTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!
        func on(_ name: String, _ callback: CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }
        on("q") { _, info in interpreter(info).save() }
        on("Q") { _, info in interpreter(info).restore() }
        on("cm") { scanner, info in interpreter(info).concat(scanner) }
        on("w") { scanner, info in interpreter(info).setLineWidth(scanner) }
        on("d") { scanner, info in interpreter(info).setDash(scanner) }
        on("G") { scanner, info in interpreter(info).setDeviceColour(scanner, .gray, stroke: true) }
        on("g") { scanner, info in interpreter(info).setDeviceColour(scanner, .gray, stroke: false)
        }
        on("RG") { scanner, info in interpreter(info).setDeviceColour(scanner, .rgb, stroke: true) }
        on("rg") { scanner, info in interpreter(info).setDeviceColour(scanner, .rgb, stroke: false)
        }
        on("K") { scanner, info in interpreter(info).setDeviceColour(scanner, .cmyk, stroke: true) }
        on("k") { scanner, info in interpreter(info).setDeviceColour(scanner, .cmyk, stroke: false)
        }
        on("SC") { scanner, info in interpreter(info).setColour(scanner, stroke: true) }
        on("SCN") { scanner, info in interpreter(info).setColour(scanner, stroke: true) }
        on("sc") { scanner, info in interpreter(info).setColour(scanner, stroke: false) }
        on("scn") { scanner, info in interpreter(info).setColour(scanner, stroke: false) }
        on("CS") { scanner, info in interpreter(info).setColourSpace(scanner, stroke: true) }
        on("cs") { scanner, info in interpreter(info).setColourSpace(scanner, stroke: false) }
        on("m") { scanner, info in interpreter(info).moveTo(scanner) }
        on("l") { scanner, info in interpreter(info).lineTo(scanner) }
        on("c") { scanner, info in interpreter(info).curveTo(scanner, kind: "c") }
        on("v") { scanner, info in interpreter(info).curveTo(scanner, kind: "v") }
        on("y") { scanner, info in interpreter(info).curveTo(scanner, kind: "y") }
        on("re") { scanner, info in interpreter(info).rectangle(scanner) }
        on("h") { _, info in interpreter(info).closePath() }
        on("W") { _, info in interpreter(info).markClip() }
        on("W*") { _, info in interpreter(info).markClip() }
        on("S") { _, info in interpreter(info).paint(.stroke) }
        on("s") { _, info in interpreter(info).paint(.stroke, close: true) }
        on("f") { _, info in interpreter(info).paint(.fill) }
        on("F") { _, info in interpreter(info).paint(.fill) }
        on("f*") { _, info in interpreter(info).paint(.fill, evenOdd: true) }
        on("B") { _, info in interpreter(info).paint(.fillAndStroke) }
        on("B*") { _, info in interpreter(info).paint(.fillAndStroke, evenOdd: true) }
        on("b") { _, info in interpreter(info).paint(.fillAndStroke, close: true) }
        on("b*") { _, info in interpreter(info).paint(.fillAndStroke, close: true, evenOdd: true) }
        on("n") { _, info in interpreter(info).paint(nil) }
        on("BT") { _, info in interpreter(info).beginText() }
        on("ET") { _, info in _ = interpreter(info) }
        on("Tf") { scanner, info in interpreter(info).setFont(scanner) }
        on("Tc") { scanner, info in interpreter(info).setTextState(scanner, "Tc") }
        on("Tw") { scanner, info in interpreter(info).setTextState(scanner, "Tw") }
        on("Tz") { scanner, info in interpreter(info).setTextState(scanner, "Tz") }
        on("TL") { scanner, info in interpreter(info).setTextState(scanner, "TL") }
        on("Ts") { scanner, info in interpreter(info).setTextState(scanner, "Ts") }
        on("Tr") { scanner, info in interpreter(info).setTextState(scanner, "Tr") }
        on("Td") { scanner, info in interpreter(info).moveText(scanner, setLeading: false) }
        on("TD") { scanner, info in interpreter(info).moveText(scanner, setLeading: true) }
        on("Tm") { scanner, info in interpreter(info).setTextMatrix(scanner) }
        on("T*") { _, info in
            let target = interpreter(info)
            target.nextLine(0, -target.state.leading)
        }
        on("Tj") { scanner, info in interpreter(info).showString(scanner) }
        on("TJ") { scanner, info in interpreter(info).showArray(scanner) }
        on("'") { scanner, info in interpreter(info).nextLineAndShow(scanner, spacing: false) }
        on("\"") { scanner, info in interpreter(info).nextLineAndShow(scanner, spacing: true) }
        on("BDC") { scanner, info in
            interpreter(info).beginMarkedContent(scanner, withProperties: true)
        }
        on("BMC") { scanner, info in
            interpreter(info).beginMarkedContent(scanner, withProperties: false)
        }
        on("EMC") { _, info in interpreter(info).endMarkedContent() }
        on("Do") { scanner, info in interpreter(info).doXObject(scanner) }
        on("EI") { _, info in interpreter(info).inlineImage() }
        on("sh") { _, info in interpreter(info).countShading() }
        return table
    }
}

extension PageInterpreter {
    /// A CoreGraphics PDF object's address, as a dictionary key for objects already read.
    static func key<T>(_ reference: T) -> Int { unsafeBitCast(reference, to: Int.self) }
}
