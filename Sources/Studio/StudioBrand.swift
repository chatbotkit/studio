import AppKit
import SwiftUI

enum StudioBrand {
    static let background = NSColor(name: "StudioBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
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
    let progress: Double
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
                    HStack(alignment: .firstTextBaseline) {
                        Text(detail).lineLimit(2)
                        Spacer(minLength: 16)
                        Text("\(Int(progress * 100))%")
                            .monospacedDigit().contentTransition(.numericText())
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(Color(nsColor: StudioBrand.foreground))
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                        }
                    }.frame(height: 3)
                        .accessibilityLabel("Startup progress")
                        .accessibilityValue("\(Int(progress * 100)) percent")
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

struct AboutStudioView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    var body: some View {
        VStack(spacing: 24) {
            CBKLogo().frame(width: 72, height: 72)
            VStack(spacing: 8) {
                Text("Studio").font(.system(size: 30, weight: .semibold))
                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Your ChatBotKit workspace.\nRunning locally on your Mac.")
                .font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Divider().frame(width: 240)
            CBKLogo(wordmark: true).frame(width: 88, height: 29)
            HStack(spacing: 22) {
                Link("ChatBotKit", destination: URL(string: "https://chatbotkit.com")!)
                Link("Source", destination: URL(string: "https://github.com/chatbotkit/studio")!)
            }.font(.caption).tint(Color(nsColor: StudioBrand.foreground))
        }
        .padding(44)
        .frame(width: 360)
        .background(Color(nsColor: StudioBrand.background))
    }
}
