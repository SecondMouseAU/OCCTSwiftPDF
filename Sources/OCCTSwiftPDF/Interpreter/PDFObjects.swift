// PDFObjects.swift
// OCCTSwiftPDF
//
// Small readers over CoreGraphics' PDF object API.

import CoreGraphics
import Foundation

enum PDFObjects {
    static func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func number(_ dict: CGPDFDictionaryRef, _ key: String) -> Double? {
        var value: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dict, key, &value) else { return nil }
        return Double(value)
    }

    static func integer(_ dict: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dict, key, &value) { return value }
        return number(dict, key).map { Int($0) }
    }

    static func dictionary(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, key, &value) else { return nil }
        return value
    }

    static func array(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &value) else { return nil }
        return value
    }

    static func stream(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var value: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dict, key, &value) else { return nil }
        return value
    }

    /// A PDF text string (PDFDocEncoding or UTF-16), such as a layer's name.
    static func text(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    static func numbers(_ array: CGPDFArrayRef) -> [Double] {
        (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var value: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, index, &value) ? Double(value) : nil
        }
    }

    static func bytes(_ string: CGPDFStringRef) -> [UInt8] {
        guard let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(string)))
    }

    static func data(_ stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        return data as Data
    }

    /// A six-number matrix array as a transform.
    static func matrix(_ array: CGPDFArrayRef) -> CGAffineTransform? {
        let values = numbers(array)
        guard values.count == 6 else { return nil }
        return CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }
}
