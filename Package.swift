// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCCTSwiftPDF",
    // The platforms OCCTSwiftIO builds for. CoreGraphics' PDF scanner is on all of them. PDFKit is
    // not used on tvOS (older SDKs lack it, and an app built with a newer one might not launch on a
    // tvOS without it), so the cross-check against it is behind `#if canImport(PDFKit) &&
    // !os(tvOS)` and a run keeps the package's own text there. The comparison's reference reader
    // runs `/usr/bin/unzip` and `pdfprobe` is a command-line tool, so both are macOS only.
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v1), .tvOS(.v18)],
    products: [
        .library(name: "OCCTSwiftPDF", targets: ["OCCTSwiftPDF"]),
        .executable(name: "pdfprobe", targets: ["pdfprobe"]),
    ],
    dependencies: [
        // The drawing model a PDF is read into, as DXF, DWG and JWW are.
        .package(url: "https://github.com/SecondMouseAU/SwiftDXF.git", from: "0.4.0"),
        // pdfprobe only: a JWW of the same drawing as the reference where its DXF is missing.
        .package(url: "https://github.com/SecondMouseAU/SwiftJWW.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "OCCTSwiftPDF",
            dependencies: [.product(name: "SwiftDXF", package: "SwiftDXF")]),
        .executableTarget(
            name: "pdfprobe",
            dependencies: ["OCCTSwiftPDF", .product(name: "SwiftJWW", package: "SwiftJWW")]),
        .testTarget(name: "OCCTSwiftPDFTests", dependencies: ["OCCTSwiftPDF"]),
    ]
)
