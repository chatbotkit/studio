# CBK artwork

Unmodified official vector assets from `chatbotkit/platform`, revision
`416104dc29a8a1bba44c0a1152a1710112dfdf9b`:

- `platform/public/icon.svg` — CBK symbol.
- `platform/public/logo.svg` — CBK wordmark.

Source: https://github.com/chatbotkit/platform/tree/416104dc29a8a1bba44c0a1152a1710112dfdf9b/platform/public

The build renders the supplied paths to monochrome template images and a
separate foreground layer for `Studio.icon.json`. The native icon is black on
white by default, white on charcoal in dark mode, and uses macOS's mono
appearance for clear and tinted styles. The CBK shape is unchanged.

`generate-brand-assets.swift` creates the Icon Composer document programmatically;
Xcode's `actool` compiles it into `Assets.car` and a compatibility ICNS. Both are
packaged, with `CFBundleIconName=Studio`. No editor step is required.

Every build renders Default, Dark, ClearLight, ClearDark, TintedLight and
TintedDark through Apple's `ictool` and checks that the foreground remains
distinct. Packaging verification checks for default, dark and mono icon stacks
in the compiled catalog. Preview PNGs and generated resources live under the
ignored `.build/Brand/` directory; source SVGs and JSON remain Git text files.

See [Apple's Icon Composer documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
for the layered appearance model. Clear/tinted colors remain controlled by
macOS and the user's chosen tint, rather than being baked into a single image.
