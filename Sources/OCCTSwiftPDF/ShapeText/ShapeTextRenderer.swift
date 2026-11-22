// ShapeTextRenderer.swift
// OCCTSwiftPDF
//
// The first step of recovering text drawn as shapes: the page rendered by CoreGraphics, a tile at a
// time, and each line of shapes cut out of it upright (turned to read left to right) with a margin.

import CoreGraphics
import Foundation

/// One line of shapes, cut out of the rendered page upright.
struct ShapeTextCrop {
    var image: CGImage
    /// Pixels per page unit.
    var scale: Double
    /// The white margin round the line's box, in page units.
    var padding: Double

    /// The point of the line's frame at a point of the image, given as a fraction of its width
    /// and height from the lower left (as Vision reports them).
    func frame(_ normalised: CGPoint) -> (a: Double, b: Double) {
        (
            normalised.x * Double(image.width) / scale - padding,
            normalised.y * Double(image.height) / scale - padding
        )
    }
}

/// A part of the page rendered at one scale.
struct ShapeTextTile {
    var image: CGImage
    /// The part of the page it covers, in page coordinates.
    var rect: CGRect
    /// Pixels per page unit.
    var scale: Double

    /// The longest side of a crop, in pixels.
    static let maximumCropSide = 4_096

    /// `region` cut out upright, or `nil` where it does not fit.
    func crop(_ region: ShapeTextRegion, padding: Double) -> ShapeTextCrop? {
        let width = Int(((region.length + 2 * padding) * scale).rounded(.up))
        let height = Int(((region.height + 2 * padding) * scale).rounded(.up))
        guard (1...Self.maximumCropSide).contains(width),
            (1...Self.maximumCropSide).contains(height),
            let context = ShapeTextRenderer.whiteContext(width: width, height: height)
        else { return nil }
        let d = region.direction
        let n = region.across
        let o = region.origin
        context.interpolationQuality = .high
        // Page to crop pixels: along the direction and across it, from the frame's origin, plus the
        // margin, times the scale.
        let alongOrigin = Double(o.x * d.x + o.y * d.y)
        let acrossOrigin = Double(o.x * n.x + o.y * n.y)
        let toPixels = CGAffineTransform(
            a: Double(d.x) * scale, b: Double(n.x) * scale, c: Double(d.y) * scale,
            d: Double(n.y) * scale, tx: (padding - alongOrigin) * scale,
            ty: (padding - acrossOrigin) * scale)
        context.concatenate(toPixels)
        context.draw(image, in: rect)
        guard let cropped = context.makeImage() else { return nil }
        return ShapeTextCrop(image: cropped, scale: scale, padding: padding)
    }
}

enum ShapeTextRenderer {
    /// The most pixels in a tile.
    static let maximumTilePixels = 48_000_000

    /// A tile's side before it is widened to take in the regions that start in it, in pixels.
    static let tileSide = 2_048.0

    /// A grey bitmap context filled white, or `nil`.
    static func whiteContext(width: Int, height: Int) -> CGContext? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// The margin round a region's box, in page units: 35 percent of its height, and at least
    /// four pixels.
    static func padding(for region: ShapeTextRegion, scale: Double) -> Double {
        max(0.35 * region.height, 4 / scale)
    }

    /// The scale a region is rendered at, in pixels per page unit: the one that makes its height
    /// `glyphPixels`, rounded to a power of the square root of two so that regions share tiles,
    /// and lowered where its crop would be over 4,096 pixels long.
    static func scale(for region: ShapeTextRegion, glyphPixels: Double) -> Double {
        let wanted = min(32, max(0.25, glyphPixels / max(region.height, 1e-6)))
        var step = (2 * log2(wanted)).rounded()
        func pixelsPerUnit(_ step: Double) -> Double { pow(2, step / 2) }
        while step > -4,
            (region.length + 2 * Self.padding(for: region, scale: pixelsPerUnit(step)))
                * pixelsPerUnit(step) > Double(ShapeTextTile.maximumCropSide)
        {
            step -= 1
        }
        return pixelsPerUnit(step)
    }

    /// Renders the page in tiles and calls `body` for each with the indices (into `regions`) of
    /// the regions cut from it.
    ///
    /// A region goes to the tile of its scale and of the square of the page its box's centre is
    /// in. A tile is rendered once, however many regions are cut from it, since each render runs
    /// the whole page.
    static func tiles(
        for regions: [ShapeTextRegion], page: CGPDFPage, glyphPixels: Double,
        _ body: (ShapeTextTile, [Int]) throws -> Void
    ) rethrows {
        struct Key: Hashable, Comparable {
            var scale: Double
            var x: Int
            var y: Int
            static func < (a: Key, b: Key) -> Bool {
                if a.scale != b.scale { return a.scale < b.scale }
                return a.x != b.x ? a.x < b.x : a.y < b.y
            }
        }
        var groups: [Key: [Int]] = [:]
        for (index, region) in regions.enumerated() {
            let regionScale = Self.scale(for: region, glyphPixels: glyphPixels)
            let side = tileSide / regionScale
            let centre = CGPoint(x: region.bounds.midX, y: region.bounds.midY)
            let key = Key(
                scale: regionScale, x: Int((centre.x / side).rounded(.down)),
                y: Int((centre.y / side).rounded(.down)))
            groups[key, default: []].append(index)
        }
        for key in groups.keys.sorted() {
            let indices = groups[key] ?? []
            var area = CGRect.null
            for index in indices {
                let region = regions[index]
                let margin = padding(for: region, scale: key.scale)
                area = area.union(region.bounds.insetBy(dx: -2 * margin, dy: -2 * margin))
            }
            if let tile = render(page, area: area, scale: key.scale) {
                try body(tile, indices)
            } else {
                // Too big as one tile: one for each region.
                for index in indices {
                    let region = regions[index]
                    let margin = padding(for: region, scale: key.scale)
                    let box = region.bounds.insetBy(dx: -2 * margin, dy: -2 * margin)
                    if let tile = render(page, area: box, scale: key.scale) {
                        try body(tile, [index])
                    }
                }
            }
        }
    }

    /// The part of the page in `area` (page coordinates) at `scale` pixels per page unit, or
    /// `nil` where it would be more than ``maximumTilePixels``.
    static func render(_ page: CGPDFPage, area: CGRect, scale: Double) -> ShapeTextTile? {
        let width = Int((area.width * scale).rounded(.up))
        let height = Int((area.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height <= maximumTilePixels,
            let context = whiteContext(width: width, height: height)
        else { return nil }
        // The page is drawn in its own user space, which is the space the interpreter reads: no
        // crop box offset and no /Rotate.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return ShapeTextTile(
            image: image,
            rect: CGRect(
                x: area.minX, y: area.minY, width: Double(width) / scale,
                height: Double(height) / scale), scale: scale)
    }
}
