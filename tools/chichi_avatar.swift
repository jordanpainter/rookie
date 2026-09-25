// Puts a chessboard behind the animated Chichi, frame by frame.
//
//   swiftc -O tools/chichi_avatar.swift -o /tmp/chichi_avatar
//   /tmp/chichi_avatar art/chichi/chichi-blink.gif art/chichi/chichi-blink-board.gif
//
// The pixel-art Chichi is white with a black outline on transparency, which
// reads fine on a light page and turns into a white blob on a dark one, where
// the outline disappears. A board behind him is legible either way, and it says
// chess without a caption. The blink survives: every frame is composited and the
// delays are copied across.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let inPath = args[1], outPath = args[2]
// Square count across the avatar. Four reads as a board at 128px; eight turns
// into texture.
let squares = args.count > 3 ? Int(args[3])! : 4
let light = (r: 0.933, g: 0.933, b: 0.824)
let dark = (r: 0.463, g: 0.588, b: 0.337)

let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil)!
let frames = CGImageSourceGetCount(src)
let first = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let size = max(first.width, first.height)
print("\(frames) frames at \(first.width)x\(first.height)")

/// The delay GIF readers agree on, in seconds.
func delay(_ index: Int) -> Double {
    let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
    return max(unclamped ?? clamped ?? 0.1, 0.02)
}

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                           UTType.gif.identifier as CFString, frames, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
                                        [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

for index in 0..<frames {
    guard let frame = CGImageSourceCreateImageAtIndex(src, index, nil) else { continue }
    let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                           bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Nearest neighbour: this is pixel art, and smoothing it is vandalism.
    canvas.interpolationQuality = .none
    let step = Double(size) / Double(squares)
    canvas.setFillColor(red: light.r, green: light.g, blue: light.b, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))
    canvas.setFillColor(red: dark.r, green: dark.g, blue: dark.b, alpha: 1)
    for row in 0..<squares { for column in 0..<squares where (row + column).isMultiple(of: 2) {
        canvas.fill(CGRect(x: Double(column) * step, y: Double(row) * step,
                           width: step, height: step))
    } }
    canvas.draw(frame, in: CGRect(x: Double(size - frame.width) / 2,
                                  y: Double(size - frame.height) / 2,
                                  width: Double(frame.width), height: Double(frame.height)))
    CGImageDestinationAddImage(dest, canvas.makeImage()!,
                               [kCGImagePropertyGIFDictionary:
                                 [kCGImagePropertyGIFDelayTime: delay(index)]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
