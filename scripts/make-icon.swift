// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(x: 55, y: 55, width: 914, height: 914)
NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.29, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 195, yRadius: 195).fill()
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 225, y: 265, width: 574, height: 390), xRadius: 32, yRadius: 32).fill()
NSBezierPath(roundedRect: NSRect(x: 190, y: 650, width: 644, height: 110), xRadius: 24, yRadius: 24).fill()
NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.29, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 400, y: 540, width: 224, height: 38), xRadius: 15, yRadius: 15).fill()
NSColor(calibratedRed: 0.92, green: 0.66, blue: 0.25, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 630, y: 160, width: 230, height: 230)).fill()
let check = NSBezierPath()
check.move(to: NSPoint(x: 684, y: 275)); check.line(to: NSPoint(x: 730, y: 231)); check.line(to: NSPoint(x: 802, y: 316))
check.lineWidth = 25; check.lineCapStyle = .round; check.lineJoinStyle = .round
NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.29, alpha: 1).setStroke(); check.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
