#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: Error {
    case cannotLoad(String)
    case cannotCreateContext(Int, Int)
    case cannotCreateImage(Int)
    case cannotWrite(String)
}

func loadImage(at path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ExportError.cannotLoad(path)
    }
    return image
}

func removingWhiteMatte(from source: CGImage) throws -> CGImage {
    let width = source.width
    let height = source.height
    let bytesPerRow = width * 4
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    let createdContext = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard createdContext else {
        throw ExportError.cannotCreateContext(width, height)
    }

    let solidThreshold = 24
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let minimum = min(red, green, blue)

        guard minimum > solidThreshold else {
            pixels[offset + 3] = 255
            continue
        }

        let alpha = max(0, min(255, (255 - minimum) * 255 / (255 - solidThreshold)))
        guard alpha > 12 else {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
            continue
        }

        let whiteMatte = 255 - alpha
        pixels[offset] = UInt8(max(0, red - whiteMatte))
        pixels[offset + 1] = UInt8(max(0, green - whiteMatte))
        pixels[offset + 2] = UInt8(max(0, blue - whiteMatte))
        pixels[offset + 3] = UInt8(alpha)
    }

    let data = Data(pixels) as CFData
    guard
        let provider = CGDataProvider(data: data),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    else {
        throw ExportError.cannotCreateImage(width)
    }
    return image
}

func export(
    _ source: CGImage,
    size: Int,
    backgroundGray: CGFloat?,
    to path: String
) throws {
    let alphaInfo: CGImageAlphaInfo = backgroundGray == nil ? .premultipliedLast : .noneSkipLast
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | alphaInfo.rawValue

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else {
        throw ExportError.cannotCreateContext(size, size)
    }

    if let backgroundGray {
        context.setFillColor(CGColor(gray: backgroundGray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    } else {
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    }

    let scale = max(CGFloat(size) / CGFloat(source.width), CGFloat(size) / CGFloat(source.height))
    let width = CGFloat(source.width) * scale
    let height = CGFloat(source.height) * scale
    let destination = CGRect(
        x: (CGFloat(size) - width) / 2,
        y: (CGFloat(size) - height) / 2,
        width: width,
        height: height
    )

    context.interpolationQuality = .high
    context.draw(source, in: destination)

    guard let image = context.makeImage() else {
        throw ExportError.cannotCreateImage(size)
    }

    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
        url,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw ExportError.cannotWrite(path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ExportError.cannotWrite(path)
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: export-app-icon.swift <light-source> <dark-source> <appiconset>\n", stderr)
    exit(2)
}

let lightSource = try loadImage(at: CommandLine.arguments[1])
let darkSource = try removingWhiteMatte(from: loadImage(at: CommandLine.arguments[2]))
let outputDirectory = CommandLine.arguments[3]

try export(
    lightSource,
    size: 1024,
    backgroundGray: 1,
    to: "\(outputDirectory)/AppIcon-Light-1024.png"
)
try export(
    darkSource,
    size: 1024,
    backgroundGray: 0,
    to: "\(outputDirectory)/AppIcon-Dark-1024.png"
)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try export(
        darkSource,
        size: size,
        backgroundGray: nil,
        to: "\(outputDirectory)/AppIcon-macOS-\(size).png"
    )
}
