// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCCTSwiftPDF",
    // CoreGraphics' PDF scanner and PDFKit are Apple frameworks. PDFKit is not on tvOS, which
    // OCCTSwiftIO also builds for, so the PDFKit use must be guarded before OCCTSwiftIO reads this.
    // The comparison's reference reader runs `/usr/bin/unzip` and is macOS only already.
    platforms: [.macOS(.v15)],
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
