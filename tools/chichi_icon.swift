// Turns Jordan's Chichi doodle into the app icon: the rook cut out of its white
// background and set on a chessboard.
//
//   swiftc -O tools/chichi_icon.swift -o /tmp/chichi_icon
//   /tmp/chichi_icon ~/doodles/chichi.png AppIcon.png
//
// The drawing is a 2048px PNG with no transparency at all: black strokes on
// opaque white. Only the white *outside* the rook can go, because the white
// inside is the rook, so this floods in from the border rather than keying out
// every white pixel. The same mistake ate the knight's mouth when the piece set
// was built, hence the flood and the seal rather than a colour key.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let inPath = args[1], outPath = args[2]
let out = args.count > 3 ? Int(args[3])! : 1024

// Board colours. Pass a name as the fourth argument; the default is the wooden
// board everybody pictures when you say chessboard.
let palettes: [String: ((r: Double, g: Double, b: Double), (r: Double, g: Double, b: Double))] = [
    "wood":   ((0.937, 0.851, 0.710), (0.710, 0.533, 0.388)),
    "green":  ((0.933, 0.933, 0.824), (0.463, 0.588, 0.337)),
    "blue":   ((0.871, 0.890, 0.902), (0.549, 0.635, 0.678)),
    "ink":    ((0.949, 0.949, 0.941), (0.290, 0.290, 0.290)),
    "walnut": ((0.910, 0.816, 0.667), (0.482, 0.294, 0.165)),
    "purple": ((0.910, 0.878, 0.949), (0.541, 0.435, 0.659)),
]
let paletteName = args.dropFirst(3).first { palettes[$0] != nil } ?? "wood"
let (light, dark) = palettes[paletteName]!
let squares = 4                     // not 8: at 32px, eight squares turn to mush
// macOS does not round an app icon for you, the way iOS does: an .icns is drawn
// exactly as given. Pass "square" for a full-bleed board; the default is the
// rounded square with a margin that every other icon in the Dock has.
let square = args.contains("square")
let boardInset = square ? 0.0 : Double(out) * 0.055
let cornerRadius = square ? 0.0 : Double(out) * 0.20

/// Chamfer distance (3-4 metric) from every pixel to the nearest seed.
func distance(_ seed: [Bool], _ w: Int, _ h: Int) -> [Double] {
    var d = seed.map { $0 ? 0.0 : 1e9 }
    for y in 0..<h { for x in 0..<w {
        let i = y * w + x; var v = d[i]
        if x > 0 { v = min(v, d[i - 1] + 3) }
        if y > 0 { v = min(v, d[i - w] + 3)
            if x > 0 { v = min(v, d[i - w - 1] + 4) }
            if x < w - 1 { v = min(v, d[i - w + 1] + 4) } }
        d[i] = v } }
    for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
        let i = y * w + x; var v = d[i]
        if x < w - 1 { v = min(v, d[i + 1] + 3) }
        if y < h - 1 { v = min(v, d[i + w] + 3)
            if x < w - 1 { v = min(v, d[i + w + 1] + 4) }
            if x > 0 { v = min(v, d[i + w - 1] + 4) } }
        d[i] = v } }
    return d.map { $0 / 3 }
}

// ---------- load ----------

let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil)!
let drawing = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = drawing.width, h = drawing.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let load = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
load.draw(drawing, in: CGRect(x: 0, y: 0, width: w, height: h))

var lum = [UInt8](repeating: 0, count: w * h)
for i in 0..<(w * h) {
    lum[i] = UInt8((Int(px[i*4]) * 299 + Int(px[i*4+1]) * 587 + Int(px[i*4+2]) * 114) / 1000)
}

// ---------- what is outside ----------

let dark_ = lum.map { $0 < 128 }
let toStroke = distance(dark_, w, h)
// Every stroke counts as this much thicker while the flood runs, so a thin spot
// in a hand-drawn line cannot let the background leak into the body.
let seal = 12.0
var outside = [Bool](repeating: false, count: w * h)
var queue: [Int] = []
func push(_ i: Int) {
    if !outside[i] && toStroke[i] > seal { outside[i] = true; queue.append(i) }
}
for x in 0..<w { push(x); push((h - 1) * w + x) }
for y in 0..<h { push(y * w); push(y * w + w - 1) }
var head = 0
while head < queue.count {
    let i = queue[head]; head += 1
    let x = i % w, y = i / w
    if x > 0 { push(i - 1) }
    if x < w - 1 { push(i + 1) }
    if y > 0 { push(i - w) }
    if y < h - 1 { push(i + w) }
}
// Grow back to the real edge of the stroke, so no white halo is left behind.
let toOutside = distance(outside, w, h)
var transparent = [Bool](repeating: false, count: w * h)
for i in 0..<(w * h) { transparent[i] = !dark_[i] && toOutside[i] <= seal + 2 }

// The cut-out drawing: strokes and the white they enclose, nothing else.
var cut = [UInt8](repeating: 0, count: w * h * 4)
for i in 0..<(w * h) {
    if transparent[i] {
        // Keep the soft edge of the stroke: its colour, its own darkness as alpha.
        let a = 255 - Int(lum[i])
        cut[i*4+3] = UInt8(a)                      // black, premultiplied, so RGB stays 0
    } else {
        let v = lum[i]
        cut[i*4] = v; cut[i*4+1] = v; cut[i*4+2] = v; cut[i*4+3] = 255
    }
}

// ---------- crop to the drawing ----------

var x0 = w, y0 = h, x1 = 0, y1 = 0
for y in 0..<h { for x in 0..<w where cut[(y * w + x) * 4 + 3] > 20 {
    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) } }
let box = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
print("drawing occupies \(Int(box.width))x\(Int(box.height)) at \(x0),\(y0)")

let cutImage = CGContext(data: &cut, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .makeImage()!.cropping(to: box)!

// ---------- the board, and Chichi on it ----------

let canvas = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: out * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.interpolationQuality = .high

let side = Double(out) - 2 * boardInset
let step = side / Double(squares)
canvas.saveGState()
if cornerRadius > 0 {
    let board = CGPath(roundedRect: CGRect(x: boardInset, y: boardInset, width: side, height: side),
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    canvas.addPath(board)
    canvas.clip()
}
canvas.setFillColor(red: light.r, green: light.g, blue: light.b, alpha: 1)
canvas.fill(CGRect(x: boardInset, y: boardInset, width: side, height: side))
canvas.setFillColor(red: dark.r, green: dark.g, blue: dark.b, alpha: 1)
for row in 0..<squares { for column in 0..<squares where (row + column).isMultiple(of: 2) {
    canvas.fill(CGRect(x: boardInset + Double(column) * step, y: boardInset + Double(row) * step,
                       width: step, height: step))
} }
canvas.restoreGState()

// Chichi, centred, tall enough to own the icon but not to touch the edges.
let scale = Double(out) * 0.72 / max(Double(cutImage.width), Double(cutImage.height))
let drawW = Double(cutImage.width) * scale, drawH = Double(cutImage.height) * scale
let rect = CGRect(x: (Double(out) - drawW) / 2, y: (Double(out) - drawH) / 2,
                  width: drawW, height: drawH)
// A soft shadow, because white line art on a light square disappears otherwise.
canvas.setShadow(offset: CGSize(width: 0, height: -Double(out) * 0.012),
                 blur: Double(out) * 0.03,
                 color: CGColor(red: 0.15, green: 0.09, blue: 0.03, alpha: 0.45))
canvas.draw(cutImage, in: rect)

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, canvas.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath) at \(out)x\(out)")
