// Renders the Deck app icon (a soft blue squircle with three stacked cards) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(red: 0.42, green: 0.70, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.16, green: 0.43, blue: 0.95, alpha: 1))!.draw(in: squircle, angle: -90)
    let card = tile.width * 0.5
    for i in 0..<3 {
        let offset = CGFloat(i) * tile.width * 0.085
        let r = NSRect(x: tile.midX - card / 2 + offset - tile.width * 0.085,
                       y: tile.midY - card * 0.36 - offset + tile.width * 0.085,
                       width: card, height: card * 0.72)
        NSColor.white.withAlphaComponent([0.35, 0.6, 1.0][i]).setFill()
        NSBezierPath(roundedRect: r, xRadius: card * 0.1, yRadius: card * 0.1).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
