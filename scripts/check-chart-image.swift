import AppKit
import Foundation
import ImageIO

// Actual simulator pixels, independently of the WebKit ready/state messages.
// The drawing frame is in window points; PNG coordinates use the measured scale.
func fail(_ message: String) -> Never {
    fputs("Chart image check failed: \(message)\n", stderr)
    exit(1)
}
let args = CommandLine.arguments
guard args.count == 4 else { fail("expected screenshot, render proof and output JSON paths") }
let input = URL(fileURLWithPath: args[1])
let proof = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as? [String: Any] ?? [:]
let frame = proof["frame"] as? [String: NSNumber] ?? [:]
func value(_ key: String) -> Double { frame[key]?.doubleValue ?? .nan }
guard let windowWidth = (proof["windowWidth"] as? NSNumber)?.doubleValue,
      let windowHeight = (proof["windowHeight"] as? NSNumber)?.doubleValue,
      windowWidth > 0, windowHeight > 0,
      [value("x"), value("y"), value("width"), value("height")].allSatisfy({ $0.isFinite }),
      value("width") > 100, value("height") > 150 else { fail("missing usable native chart frame") }
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot decode screenshot") }
let scaleX = Double(image.width) / windowWidth, scaleY = Double(image.height) / windowHeight
guard abs(scaleX - scaleY) < 0.02 else { fail("screenshot and window dimensions disagree") }
let rect = CGRect(x: CGFloat(value("x") * scaleX), y: CGFloat(value("y") * scaleY),
                  width: CGFloat(value("width") * scaleX), height: CGFloat(value("height") * scaleY)).integral
guard CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)).contains(rect),
      let crop = image.cropping(to: rect) else { fail("chart frame extends outside screenshot") }
let bitmap = NSBitmapImageRep(cgImage: crop)
let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 160)
var samples = 0, coloured = 0
for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
        guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        samples += 1
        let red = colour.redComponent, green = colour.greenComponent, blue = colour.blueComponent
        if abs(red - green) > 0.1 && max(red, green) - blue > 0.06 { coloured += 1 }
    }
}
let output = URL(fileURLWithPath: args[3])
let result: [String: Any] = ["passed": coloured > 30, "samples": samples, "colouredSamples": coloured,
    "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "runID": proof["runID"] ?? ""]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("cannot preserve cropped chart evidence") }
try png.write(to: output.deletingPathExtension().appendingPathExtension("crop.png"))
guard coloured > 30 else { fail("ready was reported, but the actual plot pixels have no coloured series") }
print("Actual chart screenshot passed: \(coloured)/\(samples) coloured samples")
