// Turns six hand-drawn pieces into the twelve-file Doodle set.
//
//   swiftc -O tools/doodle_pieces.swift -o /tmp/doodle_pieces
//   /tmp/doodle_pieces art/doodle Sources/ChessCoach/Resources/pieces/doodle
//
// The drawings are art/doodle/{K,Q,R,B,N,P}.webp, exported from Procreate with a
// transparent background and the piece filled white, all on the same square
// canvas. Their own transparency is used exactly as drawn: white pieces are the
// drawing, black pieces are its colours inverted with the same transparency.
// An earlier version ignored the transparency and tried to work out the outside
// itself by thickening every line; it sealed the narrow gap under the knight's
// mouth and filled it in.
//
// The white pieces' black lines are thickened inwards, into the fill. The two
// colours start with identical lines, one being the other inverted, but white
// lines on a dark board read heavier than black ones on white, so the white set
// looked lighter. Growing inwards only keeps both colours the same silhouette.
//
// Every piece gets one shared scale, so the sizes they were drawn at relative to
// each other are kept, and one baseline, so they all stand on the same line.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let inDir = args[1], outDir = args[2]
let letters = ["K", "Q", "R", "B", "N", "P"]
let out = 512
let thicken = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 22  // source pixels; 22 matched the black set by eye

struct Drawing { let letter: String; let w: Int; let h: Int; var px: [UInt8]; let box: CGRect }

func load(_ letter: String) -> Drawing {
    let url = URL(fileURLWithPath: "\(inDir)/\(letter).webp")
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)   // premultiplied RGBA, row 0 at the top
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var x0 = w, y0 = h, x1 = 0, y1 = 0
    for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 10 {
        x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) } }
    return Drawing(letter: letter, w: w, h: h, px: px,
                   box: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
}

/// Chamfer distance (3-4 metric) from every pixel to the nearest seed pixel.
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

/// Separate black marks smaller than this are left exactly as drawn: that is the
/// knight's eye (16,000 pixels), where every real line is 80,000 or more. Growing
/// the eye with the lines made the white knight's eye 40% bigger than the black
/// knight's, whose eye is not thickened at all.
let smallestLine = 30_000

/// Every pixel of every black mark at least `smallestLine` pixels in size.
func lines(_ px: [UInt8], _ w: Int, _ h: Int) -> [Bool] {
    var todo = (0..<(w * h)).map { px[$0 * 4 + 3] > 200 && px[$0 * 4] < 110 }
    var keep = [Bool](repeating: false, count: w * h)
    for start in 0..<(w * h) where todo[start] {
        var stack = [start], mark: [Int] = []
        todo[start] = false
        while let i = stack.popLast() {
            mark.append(i)
            let x = i % w, y = i / w
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            where nx >= 0 && nx < w && ny >= 0 && ny < h && todo[ny * w + nx] {
                todo[ny * w + nx] = false; stack.append(ny * w + nx)
            }
        }
        if mark.count >= smallestLine { for i in mark { keep[i] = true } }
    }
    return keep
}

/// Darkens the fill within `by` pixels of a line, with a one-pixel soft edge.
/// Only opaque pixels change, so nothing grows outwards into the background.
func thickened(_ d: Drawing, by r: Double) -> [UInt8] {
    var px = d.px
    let n = d.w * d.h
    let toLine = distance(lines(px, d.w, d.h), d.w, d.h)
    for i in 0..<n where px[i * 4 + 3] == 255 && toLine[i] < r + 1.5 {
        let keep = max(0, min(1, (toLine[i] - r) / 1.5))
        for c in 0..<3 { px[i * 4 + c] = UInt8(Double(px[i * 4 + c]) * keep) }
    }
    return px
}

let drawings = letters.map(load)
for d in drawings { print("\(d.letter): \(Int(d.box.width))x\(Int(d.box.height)) at \(Int(d.box.minX)),\(Int(d.box.minY))") }

let tallest = drawings.map { Double($0.box.height) }.max()!
let widest = drawings.map { Double($0.box.width) }.max()!
let scale = min(Double(out) * 0.86 / tallest, Double(out) * 0.92 / widest)
let baseline = Double(out) * 0.93
// On top of the shared scale. Drawn true to size, the pawn filled 61% of its box
// and the knight 77% against the king's 86%, which read as too small on the board;
// once they were enlarged, the rook, bishop and queen looked small in turn. The
// king stays as drawn, the tallest, and the anchor for the rest.
let enlarge: [String: Double] = ["P": 1.25, "N": 1.12, "R": 1.15, "B": 1.1, "Q": 1.05]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for d in drawings {
    for black in [false, true] {
        var px = black ? d.px : thickened(d, by: thicken)
        if black {
            // Inverting a premultiplied colour c under alpha a gives a - c.
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = px[i + 3]
                px[i] = a &- px[i]; px[i + 1] = a &- px[i + 1]; px[i + 2] = a &- px[i + 2]
            }
        }
        let full = CGContext(data: &px, width: d.w, height: d.h, bitsPerComponent: 8, bytesPerRow: d.w * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let piece = full.cropping(to: d.box)!
        let dst = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: out * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        dst.interpolationQuality = .high
        let k = scale * (enlarge[d.letter] ?? 1)
        let w = Double(piece.width) * k, h = Double(piece.height) * k
        // CoreGraphics draws from the bottom-left, so the base sits (out - baseline) up.
        dst.draw(piece, in: CGRect(x: (Double(out) - w) / 2, y: Double(out) - baseline, width: w, height: h))
        let url = URL(fileURLWithPath: "\(outDir)/\(black ? "b" : "w")\(d.letter).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, dst.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
print("wrote 12 files to \(outDir)")
