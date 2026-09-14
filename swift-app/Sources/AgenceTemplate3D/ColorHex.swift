import AppKit
import SwiftUI

/// Conversion Color <-> hex `#RRGGBB` pour Project.backgroundColorHex/
/// deviceColorHex (réglages avancés, 2026-09-07) — stocké en sRGB côté
/// Swift (ce que produit nativement un `ColorPicker` macOS), converti en
/// linéaire seulement côté headless.py au moment de l'appliquer au
/// Principled BSDF (voir apply_color_override/_srgb_to_linear).
extension Color {
    /// `nil` si `hex` est `nil` ou mal formé — laisse alors l'appelant
    /// retomber sur une couleur par défaut (voir ScrollControlView /
    /// AdvancedSettingsSheet).
    init?(hex: String?) {
        guard let hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// `#RRGGBB` — passe par `NSColor.deviceRGB` pour lire des composantes
    /// RGB fiables quel que soit l'espace colorimétrique interne choisi
    /// par le `ColorPicker` (sRGB étendu, P3…), sinon `redComponent` etc.
    /// peuvent lever une exception AppKit sur un `NSColor` qui n'est pas
    /// déjà dans un espace RGB simple.
    func toHexString() -> String {
        let ns = (NSColor(self).usingColorSpace(.deviceRGB)) ?? NSColor(self)
        let r = Int(round(ns.redComponent * 255)).clamped(to: 0...255)
        let g = Int(round(ns.greenComponent * 255)).clamped(to: 0...255)
        let b = Int(round(ns.blueComponent * 255)).clamped(to: 0...255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
