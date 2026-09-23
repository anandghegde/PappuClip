/// What macOS says about how things should look and move. One value, read on the main actor and handed
/// to a pure function, so that every accessibility branch of BAR-8a and BAR-14 is a test and not a
/// setting somebody has to turn on to see.
public struct SystemAppearanceSettings: Sendable, Equatable {
    public var isDark: Bool
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
    public var reduceMotion: Bool
    /// `…ShouldReduceTransparency`.
    public var reduceTransparency: Bool
    /// `…ShouldIncreaseContrast`.
    public var increaseContrast: Bool

    public init(
        isDark: Bool = false,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) {
        self.isDark = isDark
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }
}

/// The user's colour-mode setting. BAR-8a is the system one; BAR-8b adds the other two in M4, and
/// BAR-8c's Auto (Inverse) is 1.x.
public enum BarColorPreference: String, Sendable, Codable, CaseIterable {
    case system
    case light
    case dark
}

public enum BarColorMode: String, Sendable, Codable, CaseIterable {
    case light
    case dark
}

public enum BarBackgroundStyle: String, Sendable, Codable, CaseIterable {
    /// The vibrancy of BAR-8a: an `NSVisualEffectView` behind the buttons.
    case vibrancy
    /// What Reduce Transparency and Increase Contrast both ask for (BAR-14).
    case solid
}

public enum BarHighlightStyle: String, Sendable, Codable, CaseIterable {
    /// The system accent colour (BAR-8a).
    case accent
    /// Increase Contrast wants a highlight that does not depend on a tint the user may not distinguish.
    case contrast
}

public enum BarBorderStyle: String, Sendable, Codable, CaseIterable {
    case none
    case contrast
}

public enum BarMotionStyle: String, Sendable, Codable, CaseIterable {
    case animated
    /// Reduce Motion: BAR-12a's shaking X becomes a still one.
    case still
}

/// How the bar draws itself, once the system's settings and the user's preference have been weighed.
public struct BarAppearance: Sendable, Equatable {
    public var colorMode: BarColorMode
    public var background: BarBackgroundStyle
    public var border: BarBorderStyle
    public var highlight: BarHighlightStyle
    public var motion: BarMotionStyle

    public init(
        colorMode: BarColorMode,
        background: BarBackgroundStyle,
        border: BarBorderStyle,
        highlight: BarHighlightStyle,
        motion: BarMotionStyle
    ) {
        self.colorMode = colorMode
        self.background = background
        self.border = border
        self.highlight = highlight
        self.motion = motion
    }

    /// BAR-8a and the three accessibility settings of BAR-14, in one place.
    ///
    /// Increase Contrast drops the vibrancy as well as adding the border. Vibrancy is a translucency
    /// effect, and a setting that asks for more contrast is asking for the thing translucency takes
    /// away; turning one on and leaving the other would be a bar that obeyed the letter of the setting.
    public static func resolve(
        _ settings: SystemAppearanceSettings,
        preference: BarColorPreference = .system
    ) -> BarAppearance {
        let mode: BarColorMode
        switch preference {
        case .system: mode = settings.isDark ? .dark : .light
        case .light: mode = .light
        case .dark: mode = .dark
        }
        return BarAppearance(
            colorMode: mode,
            background: settings.reduceTransparency || settings.increaseContrast ? .solid : .vibrancy,
            border: settings.increaseContrast ? .contrast : .none,
            highlight: settings.increaseContrast ? .contrast : .accent,
            motion: settings.reduceMotion ? .still : .animated
        )
    }
}

/// Where the settings come from. `NSWorkspace` and `NSAppearance` in the app, a value in a test.
public protocol SystemAppearanceReading: Sendable {
    func currentAppearance() -> SystemAppearanceSettings
}
