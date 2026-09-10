import AppKit
import SwiftUI

enum StudioBrand {
    // Match Platform's canvas in sRGB before the page supplies its own colors.
    // This remains dynamic so native surfaces follow appearance changes.
    static let background = surface("StudioBackground", dark: 0x18, light: .white)

    private static func surface(_ name: String, dark: Int, light: NSColor) -> NSColor {
        NSColor(name: name) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return light }
            let component = CGFloat(dark) / 255
            return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
        }
    }
    static let foreground = NSColor(name: "StudioForeground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    static func image(_ name: String) -> NSImage {
        // The override is used only by the component renderer during development.
        let directory = ProcessInfo.processInfo.environment["STUDIO_BRAND_ASSETS"]
        let url = directory.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".png") }
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Brand")
        guard let url, let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled Studio brand asset: \(name)")
        }
        return image
    }
}

struct CBKLogo: View {
    var wordmark = false
    var body: some View {
        Image(nsImage: StudioBrand.image(wordmark ? "CBKLogo" : "CBKMark"))
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Color(nsColor: StudioBrand.foreground))
            .accessibilityLabel("ChatBotKit")
    }
}

struct StudioLaunchSurface: View {
    let detail: String
    let download: StartupDownload?
    let services: [(String, String)]

    var body: some View {
        ZStack {
            Color(nsColor: StudioBrand.background)
            VStack(spacing: 32) {
                VStack(spacing: 20) {
                    CBKLogo().frame(width: 64, height: 64)
                    Text("Studio").font(.system(size: 30, weight: .semibold))
                }
                VStack(spacing: 14) {
                    HStack {
                        Text(detail).lineLimit(2)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        if let percentage = download?.percentage {
                            Text(percentage)
                                .font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    // A download's measured progress is separate from startup.
                    // Native indeterminate animation covers resolving, unpacking,
                    // verification, and service startup; never invent a percentage.
                    StudioStartupProgressBar(fraction: download?.fraction)
                        .accessibilityLabel(detail)
                    Text(download?.summary ?? " ")
                        .font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 10) {
                        ForEach(services, id: \.0) { service in
                            HStack {
                                Text(service.0)
                                Spacer()
                                Text(service.1).foregroundStyle(.secondary)
                            }.font(.system(size: 11.5))
                        }
                    }.padding(.top, 6)
                }.frame(width: 360)
            }.padding(40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioStartupProgressBar: View {
    let fraction: Double?

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: fraction, total: 1)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(Color(nsColor: StudioBrand.foreground))
    }
}
