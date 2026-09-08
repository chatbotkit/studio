import AppKit
import Testing
@testable import Studio

@Test @MainActor func charcoalSurfacesMatchPlatformInSRGB() throws {
    let dark = try #require(NSAppearance(named: .darkAqua))
    let surfaces: [(NSColor, Int)] = [
        (StudioBrand.background, 0x18),
    ]
    for (surface, shade) in surfaces {
        var resolved: NSColor?
        dark.performAsCurrentDrawingAppearance { resolved = surface.usingColorSpace(.sRGB) }
        let color = try #require(resolved)
        let expected = CGFloat(shade) / 255
        #expect(abs(color.redComponent - expected) < 0.0001)
        #expect(abs(color.greenComponent - expected) < 0.0001)
        #expect(abs(color.blueComponent - expected) < 0.0001)
        #expect(color.alphaComponent == 1)
    }
}

@Test @MainActor func studioCanvasFollowsAppearanceChanges() throws {
    for (name, expected) in [(NSAppearance.Name.aqua, CGFloat(1)), (.darkAqua, CGFloat(0x18) / 255), (.aqua, CGFloat(1))] {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = StudioBrand.background.usingColorSpace(.sRGB)
        }
        let color = try #require(resolved)
        #expect(abs(color.redComponent - expected) < 0.0001)
        #expect(abs(color.greenComponent - expected) < 0.0001)
        #expect(abs(color.blueComponent - expected) < 0.0001)
    }
}
