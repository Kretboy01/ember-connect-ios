import SwiftUI

/// Ember Connect Design System
/// Unified color palette, typography, glassmorphism modifiers, and component styling.
public struct EmberTheme {
    // MARK: - Surfaces & Backgrounds
    public static let bgBase = Color(red: 7/255.0, green: 7/255.0, blue: 10/255.0)             // #07070A
    public static let bgElevated = Color(red: 14/255.0, green: 14/255.0, blue: 20/255.0)       // #0E0E14
    public static let surface1 = Color(red: 19/255.0, green: 19/255.0, blue: 28/255.0)         // #13131C
    public static let surface2 = Color(red: 26/255.0, green: 26/255.0, blue: 38/255.0)         // #1A1A26
    
    // MARK: - Ember Flame Accent Palette
    public static let accent = Color(red: 255/255.0, green: 94/255.0, blue: 58/255.0)          // #FF5E3A (Flame Coral)
    public static let accentHi = Color(red: 255/255.0, green: 160/255.0, blue: 72/255.0)       // #FFA048 (Solar Flame)
    public static let accentLo = Color(red: 224/255.0, green: 59/255.0, blue: 21/255.0)        // #E03B15 (Deep Ember)
    public static let accentGlow = Color(red: 255/255.0, green: 94/255.0, blue: 58/255.0).opacity(0.35)
    
    // MARK: - Status Colors
    public static let success = Color(red: 50/255.0, green: 215/255.0, blue: 75/255.0)        // #32D74B
    public static let warning = Color(red: 255/255.0, green: 214/255.0, blue: 10/255.0)       // #FFD60A
    public static let danger = Color(red: 255/255.0, green: 69/255.0, blue: 58/255.0)         // #FF453A
    public static let cyan = Color(red: 100/255.0, green: 210/255.0, blue: 255/255.0)         // #64D2FF
    
    // MARK: - Borders & Dividers
    public static let borderSubtle = Color.white.opacity(0.06)
    public static let borderMedium = Color.white.opacity(0.12)
    public static let borderGlow = Color(red: 255/255.0, green: 94/255.0, blue: 58/255.0).opacity(0.4)
    
    // MARK: - Gradients
    public static let flameGradient = LinearGradient(
        colors: [accent, accentHi],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    public static let darkFlameGradient = LinearGradient(
        colors: [accentLo, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    public static let glassCardGradient = LinearGradient(
        colors: [surface1.opacity(0.85), surface2.opacity(0.65)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    public static let heroMeshGradient = RadialGradient(
        gradient: Gradient(colors: [
            accent.opacity(0.22),
            accentLo.opacity(0.08),
            Color.clear
        ]),
        center: .topTrailing,
        startRadius: 20,
        endRadius: 320
    )
}

// MARK: - View Modifiers

public struct EmberGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var borderColor: Color = EmberTheme.borderMedium
    var withGlow: Bool = false
    
    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(EmberTheme.glassCardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        withGlow ? EmberTheme.borderGlow : borderColor,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: withGlow ? EmberTheme.accentGlow : Color.black.opacity(0.35),
                radius: withGlow ? 12 : 8,
                x: 0,
                y: withGlow ? 4 : 3
            )
    }
}

public struct EmberFlameButtonModifier: ViewModifier {
    var isEnabled: Bool = true
    
    public func body(content: Content) -> some View {
        content
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                Group {
                    if isEnabled {
                        EmberTheme.flameGradient
                    } else {
                        LinearGradient(
                            colors: [Color.gray.opacity(0.5), Color(white: 0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isEnabled ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
            )
            .shadow(
                color: isEnabled ? EmberTheme.accentGlow : Color.clear,
                radius: 12,
                x: 0,
                y: 4
            )
    }
}

public extension View {
    func emberGlassCard(cornerRadius: CGFloat = 18, borderColor: Color = EmberTheme.borderMedium, withGlow: Bool = false) -> some View {
        self.modifier(EmberGlassCardModifier(cornerRadius: cornerRadius, borderColor: borderColor, withGlow: withGlow))
    }
    
    func emberFlameButton(isEnabled: Bool = true) -> some View {
        self.modifier(EmberFlameButtonModifier(isEnabled: isEnabled))
    }
}
