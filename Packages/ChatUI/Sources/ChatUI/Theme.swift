import HybridRouterKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Route colors: Lagoon (on-device), Iris (Apple Cloud) and Clay (Claude).
///
/// Each route has an ink for text and symbols (at least 4.5:1 on the canvas and cards, 7:1
/// with Increase Contrast), a fill for badges and edges, and a glow that is only decorative
/// and never sits behind text. Teal rather than green keeps On-device and Claude apart for
/// red-green color blindness.
extension Route {
    /// Text and symbols in the route's color.
    public var ink: Color {
        switch self {
        case .onDevice: Theme.color(light: 0x006468, dark: 0x5ED6D0, lightHigh: 0x004F53, darkHigh: 0x9AF0EA)
        case .appleCloud: Theme.color(light: 0x4246CC, dark: 0xA3ADFF, lightHigh: 0x3131AE, darkHigh: 0xC6CCFF)
        case .claude: Theme.color(light: 0x9C4220, dark: 0xF29A78, lightHigh: 0x7E3216, darkHigh: 0xFFC2A8)
        }
    }

    /// Badge backgrounds, edges and the tinted Send button.
    public var fill: Color {
        switch self {
        case .onDevice: Theme.color(light: 0x007C80, dark: 0x3FD0C8, lightHigh: 0x005E62, darkHigh: 0x86EAE3)
        case .appleCloud: Theme.color(light: 0x5157E0, dark: 0x7880FF, lightHigh: 0x3A3CC4, darkHigh: 0xB4BCFF)
        case .claude: Theme.color(light: 0xB04E2C, dark: 0xE07B56, lightHigh: 0x8E3A1A, darkHigh: 0xFFB291)
        }
    }

    /// Decorative only: edges, the ambient wash and the empty-state mesh. Never behind text.
    public var glow: Color {
        switch self {
        case .onDevice: Theme.color(light: 0x36C9C0, dark: 0x8AF5EA)
        case .appleCloud: Theme.color(light: 0x8EA2FF, dark: 0xC2C9FF)
        case .claude: Theme.color(light: 0xF0956E, dark: 0xFFC0A3)
        }
    }

    /// The route's color everywhere in the UI. Same as ``ink``.
    public var tint: Color { ink }
}

/// The app's neutrals: a warm off-white canvas, white cards and neutral user bubbles.
public enum Theme {
    public static let canvas = color(light: 0xF6F4EF, dark: 0x111113)
    public static let card = color(light: 0xFFFFFF, dark: 0x1C1C1F)
    public static let userBubble = color(light: 0xE8E4DA, dark: 0x2C2C30, lightHigh: 0xDCD6C8, darkHigh: 0x3A3A40)
    public static let userText = color(light: 0x141413, dark: 0xF6F4EF)
    /// Near-black in light mode, off-white in dark mode: monochrome controls and Send on Auto.
    public static let ink = color(light: 0x141413, dark: 0xF2F0EA)
    /// Labels on a route fill or on ``ink``.
    public static let labelOnFill = color(light: 0xFFFFFF, dark: 0x141413)
    public static let hairline = color(light: 0xE6E2D8, dark: 0x2A2A2E, lightHigh: 0xB8B2A4, darkHigh: 0x55555C)

    static func color(light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) -> Color {
        let lightHigh = lightHigh ?? light
        let darkHigh = darkHigh ?? dark
        #if canImport(UIKit)
        return Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHigh = traits.accessibilityContrast == .high
            return platformColor(isDark ? (isHigh ? darkHigh : dark) : (isHigh ? lightHigh : light))
        })
        #else
        return Color(NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: platformColor(dark)
            case .accessibilityHighContrastAqua: platformColor(lightHigh)
            case .accessibilityHighContrastDarkAqua: platformColor(darkHigh)
            default: platformColor(light)
            }
        })
        #endif
    }

    #if canImport(UIKit)
    private static func platformColor(_ hex: UInt32) -> UIColor {
        UIColor(red: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1)
    }
    #else
    private static func platformColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: channel(hex, 16), green: channel(hex, 8), blue: channel(hex, 0), alpha: 1)
    }
    #endif

    private static func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat {
        CGFloat((hex >> shift) & 0xFF) / 255
    }
}

/// One motion spec for the whole app. Bounce stays at or below 0.3.
public enum Motion {
    /// A route being decided or changing.
    public static let route = Animation.spring(duration: 0.45, bounce: 0.18)
    /// Cards and rows arriving.
    public static let card = Animation.smooth(duration: 0.35)
    /// Small state changes on badges and chips.
    public static let badge = Animation.snappy(duration: 0.25)
    public static let fade = Animation.easeOut(duration: 0.2)
}

extension EnvironmentValues {
    /// The route of the reply being rendered, so structured cards can use its color.
    @Entry public var replyRoute: Route? = nil
}

/// A route-tinted capsule background: the fill at low opacity, plus an ink stroke with
/// Increase Contrast so the shape doesn't rely on a faint tint.
struct RouteCapsuleBackground: ViewModifier {
    let route: Route?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let isHigh = contrast == .increased
        let opacity = colorScheme == .dark ? (isHigh ? 0.30 : 0.22) : (isHigh ? 0.24 : 0.16)
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        content
            .background((route?.fill ?? Color.secondary).opacity(route == nil ? 0.12 : opacity), in: shape)
            .overlay {
                if isHigh, let route {
                    shape.strokeBorder(route.ink, lineWidth: 1)
                }
            }
    }
}

extension View {
    func routeCapsule(_ route: Route?) -> some View {
        modifier(RouteCapsuleBackground(route: route))
    }
}
