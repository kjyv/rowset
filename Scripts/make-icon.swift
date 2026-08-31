// Draws the app icon and writes every size the asset catalog asks for.
//
// Run it with:  swift Scripts/make-icon.swift
//
// The icon is code and not a binary blob, so a colour or a proportion can be changed and the
// whole set redrawn.

import AppKit
import CoreGraphics
import Foundation

let background = (
    top: NSColor(srgbRed: 0.32, green: 0.55, blue: 0.96, alpha: 1),
    bottom: NSColor(srgbRed: 0.10, green: 0.20, blue: 0.55, alpha: 1)
)

let headerColor = NSColor(white: 1, alpha: 0.50)
let rowColor = NSColor(white: 1, alpha: 0.92)
let selectedColor = NSColor(srgbRed: 0.99, green: 0.75, blue: 0.18, alpha: 1)

/// Where the two columns split, as a share of the width.
let columnSplit: CGFloat = 0.42

func drawIcon(size: CGFloat, into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // The rounded square, with the margin that a macOS icon keeps.
    let margin = size * 0.055
    let plate = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = plate.width * 0.2237
    let shape = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [background.bottom.cgColor, background.top.cgColor] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.minY),
        end: CGPoint(x: plate.maxX, y: plate.maxY),
        options: [])
    context.restoreGState()

    // A header band over three rows of two cells. The gap between the cells is what makes the
    // block read as a table and not as a list.
    let content = plate.insetBy(dx: plate.width * 0.19, dy: plate.height * 0.22)
    let bandCount: CGFloat = 4
    let gapShare: CGFloat = 0.42
    let bandHeight = content.height / (bandCount + (bandCount - 1) * gapShare)
    let gap = bandHeight * gapShare
    let columnGap = content.width * 0.06
    let corner = bandHeight * 0.30

    func fill(_ rect: CGRect, _ color: NSColor) {
        context.addPath(
            CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    func bandRect(_ index: Int) -> CGRect {
        let y = content.maxY - bandHeight - CGFloat(index) * (bandHeight + gap)
        return CGRect(x: content.minX, y: y, width: content.width, height: bandHeight)
    }

    // The header runs the whole width.
    fill(bandRect(0), headerColor)

    // Each row is two cells, and the middle one is the row you picked.
    for index in 1...3 {
        let band = bandRect(index)
        let color = index == 2 ? selectedColor : rowColor
        let leftWidth = band.width * columnSplit - columnGap / 2
        fill(CGRect(x: band.minX, y: band.minY, width: leftWidth, height: band.height), color)

        let rightX = band.minX + band.width * columnSplit + columnGap / 2
        let rightWidth = band.maxX - rightX
        fill(CGRect(x: rightX, y: band.minY, width: rightWidth, height: band.height), color)
    }
}

func makePNG(size: Int) -> Data {
    let width = size
    let height = size
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    drawIcon(size: CGFloat(size), into: context)

    let image = context.makeImage()!
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: width, height: height)
    return representation.representation(using: .png, properties: [:])!
}

// name, pixel size
let outputs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let folder = root.appending(path: "Sources/Rowset/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for (name, size) in outputs {
    try makePNG(size: size).write(to: folder.appending(path: "\(name).png"))
    print("wrote \(name).png at \(size) points")
}
