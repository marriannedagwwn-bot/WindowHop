import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                       ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),
                       ("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels)/1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    // Match the 824-point artwork footprint used by macOS rounded-square icons.
    // Scale the complete design together, leaving 100 points of transparent inset.
    let artworkTransform = NSAffineTransform()
    artworkTransform.translateX(by: 512, yBy: 512)
    artworkTransform.scale(by: 824.0 / 944.0)
    artworkTransform.translateX(by: -512, yBy: -512)
    artworkTransform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.15, blue: 0.23, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.12, alpha: 1))!.draw(in: background, angle: -60)
    let rear = NSBezierPath(roundedRect: NSRect(x: 216, y: 400, width: 470, height: 350), xRadius: 48, yRadius: 48)
    NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.50, alpha: 1).setFill(); rear.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 336, y: 260, width: 470, height: 350), xRadius: 48, yRadius: 48)
    NSGradient(starting: NSColor(calibratedRed: 0.38, green: 0.88, blue: 0.88, alpha: 1), ending: NSColor(calibratedRed: 0.25, green: 0.65, blue: 0.81, alpha: 1))!.draw(in: front, angle: -90)
    NSColor.white.withAlphaComponent(0.48).setFill(); NSBezierPath(roundedRect: NSRect(x: 370, y: 548, width: 400, height: 12), xRadius: 6, yRadius: 6).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name+".png"))
}
