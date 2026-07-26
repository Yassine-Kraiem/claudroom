#!/usr/bin/env swift
//
// Renders the Claudroom app icon at every size macOS asks for.
//
// The mark is a ring that is mostly *empty*: the bright arc is capacity still
// available, the dim arc is what has been used. The icon says the same thing the
// app does — look at the gap, not the fill.
//
// Usage: swift Scripts/make-icon.swift <output-dir>

import AppKit
import CoreGraphics
import Foundation

let usedFraction = 0.28

func srgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: 1)
}

// Claude's palette: warm terracotta on cream. Deliberately the ecosystem's colours
// rather than Anthropic's asterisk logomark — this reads as a Claude tool without
// pretending to be an official one.
let bgTop     = srgb(247, 245, 240)  // warm cream, light
let bgBottom  = srgb(235, 231, 222)  // warm cream, shaded
let trackDim  = srgb(214, 208, 196)  // used capacity — warm taupe, recessive
let accentA   = srgb(217, 119, 87)   // terracotta
let accentB   = srgb(193, 95, 60)    // deeper clay

/// macOS icons are a squircle inset inside the canvas, not a full-bleed square.
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect,
           cornerWidth: rect.width * 0.2237,
           cornerHeight: rect.height * 0.2237,
           transform: nil)
}

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size
    guard let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // Background squircle, inset the way Apple's grid expects.
    let inset = scale * 0.0586
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = squirclePath(in: body)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: [bgTop, bgBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // Ring geometry.
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = scale * 0.275
    let lineWidth = scale * 0.105
    ctx.setLineCap(.round)

    // Used capacity: dim and thinner, so the bright remainder dominates.
    let start = CGFloat.pi / 2                       // 12 o'clock
    let usedSweep = CGFloat(usedFraction) * 2 * .pi
    ctx.setLineWidth(lineWidth * 0.72)
    ctx.setStrokeColor(trackDim)
    ctx.addArc(center: center, radius: radius,
               startAngle: start, endAngle: start - usedSweep,
               clockwise: true)
    ctx.strokePath()

    // Claudroom: the bright remainder, with a small gap either side so the two
    // arcs read as separate quantities rather than one continuous ring.
    let gap = CGFloat.pi * 0.045
    ctx.setLineWidth(lineWidth)
    ctx.saveGState()
    ctx.addArc(center: center, radius: radius,
               startAngle: start - usedSweep - gap,
               endAngle: start + gap,
               clockwise: true)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: [accentA, accentB] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // Ceiling tick at 12 o'clock: the limit the headroom is measured against.
    let tickH = scale * 0.055
    let tickW = scale * 0.017
    ctx.setFillColor(srgb(43, 42, 40))
    let tick = CGRect(x: center.x - tickW / 2,
                      y: center.y + radius + lineWidth * 0.62,
                      width: tickW, height: tickH)
    ctx.addPath(CGPath(roundedRect: tick, cornerWidth: tickW / 2,
                       cornerHeight: tickW / 2, transform: nil))
    ctx.fillPath()

    return ctx.makeImage()
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

// (logical size, scale) pairs iconutil expects.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for (logical, scale) in variants {
    let pixels = logical * scale
    guard let image = drawIcon(size: CGFloat(pixels)) else {
        FileHandle.standardError.write(Data("failed at \(pixels)px\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }

    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(logical)x\(logical)\(suffix).png"
    try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("  \(name)  \(pixels)x\(pixels)")
}
