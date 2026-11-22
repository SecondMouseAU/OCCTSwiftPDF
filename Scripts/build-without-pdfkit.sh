#!/usr/bin/env bash
# build-without-pdfkit.sh: build the package for a platform with PDFKit rewritten out.
#
# PDFKit is not used on tvOS, but a recent tvOS SDK has the framework, so a plain tvOS build would
# still compile a PDFKit use that sits outside a guard. This copies the package, points every
# `canImport(PDFKit)` and `import PDFKit` in Sources at a module that does not exist, and builds
# that. A PDFKit use outside a guard then fails to compile on any Xcode. The working tree is not
# touched.
#
# Usage:
#   Scripts/build-without-pdfkit.sh            # tvOS
#   Scripts/build-without-pdfkit.sh iOS
set -euo pipefail

platform="${1:-tvOS}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rsync -a --exclude .build --exclude .git --exclude .claude "$root/" "$work/pkg/"
cd "$work/pkg"

# An import is any line that starts, after attributes, with `import` and an optional kind
# (`import struct PDFKit.X`, `@preconcurrency import PDFKit`, `import PDFKit // note`).
grep -rl 'PDFKit' Sources | xargs sed -i '' -E \
    -e 's/canImport\([[:space:]]*PDFKit[[:space:]]*\)/canImport(PDFKitAbsent)/g' \
    -e 's/^([[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?)PDFKit/\1PDFKitAbsent/'

# The rewrite must have caught every import and guard: one it missed (`import CoreGraphics;
# import PDFKit`) would build on an SDK that has PDFKit and defeat the point.
if grep -rnE '(^|;)[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?PDFKit([^A]|$)|canImport\([[:space:]]*PDFKit[[:space:]]*\)' Sources; then
    echo "build-without-pdfkit: an import of PDFKit was not rewritten (lines above)" >&2
    exit 1
fi

xcodebuild build \
    -scheme OCCTSwiftPDF-Package \
    -destination "generic/platform=$platform" \
    -derivedDataPath "$work/DerivedData" \
    -skipPackagePluginValidation
