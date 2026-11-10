import AppKit
// usage: svg2png in.svg out.png RRGGBB size
let a = CommandLine.arguments
guard a.count >= 5, let img = NSImage(contentsOfFile: a[1]) else { print("cannot load \(a.count > 1 ? a[1] : "")"); exit(1) }
let size = CGFloat(Int(a[4]) ?? 256)
let hex = UInt32(a[3], radix: 16) ?? 0
let color = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 0, y: 0, width: size, height: size)
img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
color.setFill()
r.fill(using: .sourceIn)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("ok \(a[2])")
