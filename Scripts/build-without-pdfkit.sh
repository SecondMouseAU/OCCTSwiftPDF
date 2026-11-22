#!/usr/bin/env bash
# build-without-pdfkit.sh: build the package for a platform as if its SDK had no PDFKit.
#
# Some tvOS SDKs have no PDFKit and newer ones do, so a plain tvOS build proves the guard only
# where the SDK lacks it. This copies the package, points every `canImport(PDFKit)` and
# `import PDFKit` in Sources at a module that does not exist, and builds that. A PDFKit use outside
# a guard then fails to compile on any Xcode. The working tree is not touched.
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

grep -rl 'PDFKit' Sources | xargs sed -i '' -E \
    -e 's/canImport\(PDFKit\)/canImport(PDFKitAbsent)/' \
    -e 's/^( *)import PDFKit$/\1import PDFKitAbsent/'

xcodebuild build \
    -scheme OCCTSwiftPDF-Package \
    -destination "generic/platform=$platform" \
    -skipPackagePluginValidation
