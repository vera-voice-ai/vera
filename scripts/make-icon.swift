// Draws Vera's app icon (1024×1024 PNG): Hermes as a solid yellow-orange core, Vera around it as a dashed pink ring,
// her voice as a waveform across. Run: swift scripts/make-icon.swift <out.png>; scripts/make-icon.sh builds the .icns.
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// macOS icon body: a rounded square inside the canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0.10, 0.05, 0.11), rgb(0.035, 0.025, 0.047)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
let c = CGPoint(x: 512, y: 512)
// glow
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0.96, 0.62, 0.04, 0.40), rgb(0.96, 0.62, 0.04, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 360, options: [])
// Vera: dashed pink ring
ctx.setStrokeColor(rgb(0.94, 0.13, 0.61))
ctx.setLineWidth(22)
ctx.setLineDash(phase: 0, lengths: [46, 30])
ctx.strokeEllipse(in: CGRect(x: c.x - 300, y: c.y - 300, width: 600, height: 600))
ctx.setLineDash(phase: 0, lengths: [])
// Hermes: solid yellow-orange core
ctx.setFillColor(rgb(0.96, 0.62, 0.04))
ctx.fillEllipse(in: CGRect(x: c.x - 190, y: c.y - 190, width: 380, height: 380))
// voice: waveform bars across the core
let heights: [Double] = [60, 120, 210, 300, 360, 300, 210, 120, 60]
let w = 30.0, gap = 18.0
let total = Double(heights.count) * w + Double(heights.count - 1) * gap
for (i, h) in heights.enumerated() {
    let x = c.x - total / 2 + Double(i) * (w + gap)
    let r = CGRect(x: x, y: c.y - h / 2, width: w, height: h)
    ctx.setFillColor(rgb(1, 1, 1, 0.95))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)); ctx.fillPath()
}
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
