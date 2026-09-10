import AppKit
import Foundation

func require(_ condition: Bool, _ message: String) throws {
  if !condition {
    throw NSError(domain: "StudioIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

func main() throws {
  try require(
    CommandLine.arguments.count == 3,
    "Usage: verify-icon.swift --catalog Assets.car | --renders directory")
  let mode = CommandLine.arguments[1]
  let path = CommandLine.arguments[2]
  if mode == "--catalog" {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["assetutil", "--info", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Could not inspect compiled icon catalog.")
    let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    let appearances = Set(
      entries.filter {
        $0["Name"] as? String == "Studio" && $0["AssetType"] as? String == "IconImageStack"
      }.compactMap { $0["Appearance"] as? String })
    try require(
      appearances.isSuperset(of: [
        "NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable",
      ]), "The app is missing a compiled default, dark or mono icon stack.")
    try require(
      entries.contains {
        $0["Name"] as? String == "Studio_Assets/Mark" && $0["AssetType"] as? String == "Image"
      }, "The foreground icon layer is missing.")
    print("Verified compiled default, dark and mono icon stacks and separate CBK foreground.")
  } else if mode == "--renders" {
    func luminance(_ color: NSColor) -> Double {
      let color = color.usingColorSpace(.sRGB)!
      func linear(_ value: CGFloat) -> Double {
        let value = Double(value)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722
        * linear(color.blueComponent)
    }
    for appearance in ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"] {
      let file = URL(fileURLWithPath: path).appendingPathComponent("\(appearance).png")
      let data = try Data(contentsOf: file)
      guard let image = NSBitmapImageRep(data: data) else {
        throw NSError(domain: "Invalid icon render", code: 1)
      }
      try require(
        image.pixelsWide >= 64 && image.pixelsWide == image.pixelsHigh, "Invalid icon dimensions.")
      // These interior points lie in the CBK left stroke and central cutout,
      // away from antialiasing and the system's edge highlights.
      let foreground = luminance(image.colorAt(x: image.pixelsWide / 4, y: image.pixelsHigh / 2)!)
      let background = luminance(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)!)
      let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
      // Default/dark are ours; clear/tinted colors are controlled by macOS.
      // This detects the disappearing-mark regression, not WCAG compliance
      // across every user-selected tint and wallpaper.
      let minimum: Double = ["Default", "Dark"].contains(appearance) ? 7 : 2
      try require(
        contrast >= minimum, "\(appearance) icon lost its foreground contrast (\(contrast)).")
      try require(
        appearance == "Default" ? foreground < background : foreground > background,
        "\(appearance) icon has the wrong foreground polarity.")
      print("\(appearance): foreground contrast \(String(format: "%.2f", contrast)):1")
    }
  } else {
    throw NSError(
      domain: "Usage: verify-icon.swift --catalog Assets.car | --renders directory", code: 1)
  }
}

do { try main() } catch {
  FileHandle.standardError.write(
    Data("Icon verification failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
