import CoreGraphics
// Real mouse clicks at screen points: swiftc -O tools/click.swift -o /tmp/click
// then /tmp/click x1 y1 [x2 y2 ...]. The board and text fields ignore
// accessibility "presses"; only real events reach them. Check the target app is
// frontmost first: a click that lands on another window is a real click there.
import Foundation
// Real mouse clicks, in points from the top-left of the main display.
let args = CommandLine.arguments.dropFirst().compactMap(Double.init)
var i = args.startIndex
while i + 1 < args.endIndex {
    let p = CGPoint(x: args[i], y: args[i + 1])
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(350_000)
    i += 2
}
