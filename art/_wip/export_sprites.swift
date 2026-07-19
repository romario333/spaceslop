import AppKit

struct Spec { let input: String; let output: String; let canvas: (Int, Int); let content: (Int, Int); let pixel: Bool }

let args = CommandLine.arguments
if args.count == 3 && args[1] == "palette" {
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(0x1a,0x1c,0x2c),(0x29,0x36,0x6f),(0x3b,0x5d,0xc9),(0x41,0xa6,0xf6),(0x38,0xb7,0x64),(0x25,0x71,0x79),(0xf4,0xf4,0xf4),(0x94,0xb0,0xc2),(0x56,0x6c,0x86),(0x33,0x3c,0x57),(0xef,0x7d,0x57),(0xb1,0x3e,0x53),(0xd9,0xa0,0x66),(0x20,0x3f,0x70),(0xd9,0xdf,0xe8),(0x6a,0x4c,0x93)]
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 256, height: 16, bitsPerComponent: 8, bytesPerRow: 1024, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, c) in colors.enumerated() { context.setFillColor(red: c.0/255, green: c.1/255, blue: c.2/255, alpha: 1); context.fill(CGRect(x: i * 16, y: 0, width: 16, height: 16)) }
    let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
guard args.count == 8 else { fatalError("usage: export_sprites.swift input output canvasW canvasH contentW contentH pixel(0|1)") }
let spec = Spec(input: args[1], output: args[2], canvas: (Int(args[3])!, Int(args[4])!), content: (Int(args[5])!, Int(args[6])!), pixel: args[7] == "1")

guard let image = NSImage(contentsOfFile: spec.input), let tiff = image.tiffRepresentation,
      let source = NSBitmapImageRep(data: tiff) else { fatalError("could not load source") }
let sw = source.pixelsWide, sh = source.pixelsHigh
var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
for y in 0..<sh { for x in 0..<sw {
    let c = source.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    let r = UInt8((c.redComponent * 255).rounded()), g = UInt8((c.greenComponent * 255).rounded()), b = UInt8((c.blueComponent * 255).rounded())
    let i = (y * sw + x) * 4
    // Image sources use a flat magenta key. Treat strongly-magenta pixels as background.
    let keyed = r > 190 && b > 190 && g < 90
    rgba[i] = keyed ? 0 : r; rgba[i+1] = keyed ? 0 : g; rgba[i+2] = keyed ? 0 : b
    rgba[i+3] = keyed ? 0 : 255
} }
var minX = sw, minY = sh, maxX = -1, maxY = -1
for y in 0..<sh { for x in 0..<sw where rgba[(y * sw + x) * 4 + 3] > 0 {
    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
} }
guard maxX >= minX else { fatalError("no opaque pixels") }
let bw = maxX - minX + 1, bh = maxY - minY + 1
let scale = min(Double(spec.content.0) / Double(bw), Double(spec.content.1) / Double(bh))
let dw = max(1, Int((Double(bw) * scale).rounded())), dh = max(1, Int((Double(bh) * scale).rounded()))
let dx = (spec.canvas.0 - dw) / 2, dy = (spec.canvas.1 - dh) / 2

let cs = CGColorSpaceCreateDeviceRGB()
var output = [UInt8](repeating: 0, count: spec.canvas.0 * spec.canvas.1 * 4)
guard let srcCtx = CGContext(data: &rgba, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = srcCtx.makeImage(),
      let out = CGContext(data: &output, width: spec.canvas.0, height: spec.canvas.1, bitsPerComponent: 8, bytesPerRow: spec.canvas.0 * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("could not create context") }
out.interpolationQuality = spec.pixel ? .none : .high
out.clear(CGRect(x: 0, y: 0, width: spec.canvas.0, height: spec.canvas.1))
out.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh), byTiling: false)
if spec.pixel {
    let palette: [(Int, Int, Int)] = [(0x1a,0x1c,0x2c),(0x29,0x36,0x6f),(0x3b,0x5d,0xc9),(0x41,0xa6,0xf6),(0x38,0xb7,0x64),(0x25,0x71,0x79),(0xf4,0xf4,0xf4),(0x94,0xb0,0xc2),(0x56,0x6c,0x86),(0x33,0x3c,0x57),(0xef,0x7d,0x57),(0xb1,0x3e,0x53),(0xd9,0xa0,0x66),(0x20,0x3f,0x70),(0xd9,0xdf,0xe8),(0x6a,0x4c,0x93)]
    for i in stride(from: 0, to: output.count, by: 4) where output[i + 3] > 0 {
        let r = Int(output[i]), g = Int(output[i + 1]), b = Int(output[i + 2])
        let near = palette.min { a, z in (a.0-r)*(a.0-r)+(a.1-g)*(a.1-g)+(a.2-b)*(a.2-b) < (z.0-r)*(z.0-r)+(z.1-g)*(z.1-g)+(z.2-b)*(z.2-b) }!
        output[i] = UInt8(near.0); output[i + 1] = UInt8(near.1); output[i + 2] = UInt8(near.2); output[i + 3] = 255
    }
}
guard let result = out.makeImage() else { fatalError("no output") }
let rep = NSBitmapImageRep(cgImage: result)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try png.write(to: URL(fileURLWithPath: spec.output))
