// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCCTSwiftPDF",
    // CoreGraphics' PDF scanner and PDFKit are Apple frameworks. PDFKit is not on tvOS, which
    // OCCTSwiftIO also builds for, so the PDFKit use must be guarded before OCCTSwiftIO reads this.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OCCTSwiftPDF", targets: ["OCCTSwiftPDF"]),
        .executable(name: "pdfprobe", targets: ["pdfprobe"]),
    ],
    dependencies: [
        // The drawing model a PDF is read into, as DXF, DWG and JWW are.
        .package(url: "https://github.com/SecondMouseAU/SwiftDXF.git", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "OCCTSwiftPDF",
            dependencies: [.product(name: "SwiftDXF", package: "SwiftDXF")]),
        .executableTarget(name: "pdfprobe", dependencies: ["OCCTSwiftPDF"]),
        .testTarget(name: "OCCTSwiftPDFTests", dependencies: ["OCCTSwiftPDF"]),
    ]
)
