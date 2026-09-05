import AppKit
import Foundation

// Render the upstream SVG paths directly, preserving the CBK geometry.
// These source assets use absolute M/L/H/V/C/Z path commands only.
final class SVG: NSObject, XMLParserDelegate {
    var paths: [CGPath] = []
    var size = CGSize.zero
    var failure: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "svg", let box = attributes["viewBox"] {
            let values = box.split(separator: " ").compactMap { Double($0) }
            if values.count == 4 { size = CGSize(width: values[2], height: values[3]) }
        }
        guard name == "path", let data = attributes["d"] else { return }
        let regex = try! NSRegularExpression(pattern: "[A-Za-z]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?")
        let tokens = regex.matches(in: data, range: NSRange(data.startIndex..., in: data)).map {
            String(data[Range($0.range, in: data)!])
        }
        let path = CGMutablePath()
        var i = 0
        var command = ""
        func number() throws -> CGFloat {
            guard i < tokens.count, let value = Double(tokens[i]) else { throw NSError(domain: "SVG", code: 1) }
            i += 1
            return CGFloat(value)
        }
        do {
            while i < tokens.count {
                if tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
                switch command {
                case "M": path.move(to: CGPoint(x: try number(), y: try number())); command = "L"
                case "L": path.addLine(to: CGPoint(x: try number(), y: try number()))
                case "H": path.addLine(to: CGPoint(x: try number(), y: path.currentPoint.y))
                case "V": path.addLine(to: CGPoint(x: path.currentPoint.x, y: try number()))
                case "C":
                    let p1 = CGPoint(x: try number(), y: try number())
                    let p2 = CGPoint(x: try number(), y: try number())
                    let p3 = CGPoint(x: try number(), y: try number())
                    path.addCurve(to: p3, control1: p1, control2: p2)
                case "Z", "z": path.closeSubpath(); command = ""
                default: throw NSError(domain: "Unsupported SVG command: \(command)", code: 2)
                }
            }
            paths.append(path)
        } catch { failure = String(describing: error) }
    }

    static func load(_ url: URL) throws -> SVG {
        let svg = SVG()
        let parser = XMLParser(data: try Data(contentsOf: url))
        parser.delegate = svg
        guard parser.parse(), svg.failure == nil, !svg.paths.isEmpty, svg.size.width > 0 else {
            throw NSError(domain: svg.failure ?? "Invalid SVG", code: 3)
        }
        return svg
    }

    func render(width: Int, height: Int, icon: Bool, to url: URL) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if icon {
            let inset = CGFloat(width) * 0.065
            let tile = CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: tile, cornerWidth: CGFloat(width) * 0.19, cornerHeight: CGFloat(height) * 0.19, transform: nil))
            context.fillPath()
        }
        let fraction: CGFloat = icon ? 0.54 : 1
        let scale = min(CGFloat(width) / size.width, CGFloat(height) / size.height) * fraction
        context.translateBy(x: (CGFloat(width) - size.width * scale) / 2, y: (CGFloat(height) + size.height * scale) / 2)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for path in paths { context.addPath(path); context.drawPath(using: .eoFill) }
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let iconset = output.appendingPathComponent("Studio.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let mark = try SVG.load(input.appendingPathComponent("icon.svg"))
let logo = try SVG.load(input.appendingPathComponent("logo.svg"))
try mark.render(width: 512, height: 512, icon: false, to: output.appendingPathComponent("CBKMark.png"))
try logo.render(width: 1156, height: 372, icon: false, to: output.appendingPathComponent("CBKLogo.png"))
for size in [16, 32, 128, 256, 512] {
    try mark.render(width: size, height: size, icon: true, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try mark.render(width: size * 2, height: size * 2, icon: true, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
