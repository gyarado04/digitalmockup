import Foundation
import Observation

/// Bascule mode clair/sombre — portage de app/ui/theme.py:apply_theme +
/// main_window.py:_toggle_theme. INDÉPENDANT de l'apparence système macOS
/// (contrairement à ce que faisait ThemedRoot avant ce fichier, qui suivait
/// `@Environment(\.colorScheme)`) : exactement comme côté Python (QSettings
/// "theme_mode", défaut "dark"), c'est un choix explicite de l'utilisateur
/// dans l'app, pas un suivi automatique du réglage système.
///
/// Singleton partagé (même mécanique que TemplatePickerSpacing/
/// ProjectViewSpacing) plutôt que rattaché à AppState : ThemedRoot est
/// aussi utilisé par les fenêtres de panneau de debug (SpacingDebugPanel),
/// qui n'ont pas forcément AppState dans leur environnement.
@MainActor
@Observable
final class ThemePreference {
    static let shared = ThemePreference()

    private static let defaultsKey = "theme_mode"

    /// Propriété STOCKÉE (pas calculée à la volée depuis UserDefaults) —
    /// même piège déjà rencontré plusieurs fois dans ce projet
    /// (hasChosenProjectsRoot, etc.) : `@Observable` ne suit que les
    /// propriétés stockées, jamais une calculée qui lit une source externe.
    private(set) var isLight: Bool

    private init() {
        isLight = UserDefaults.standard.string(forKey: Self.defaultsKey) == "light"
    }

    func setLight(_ light: Bool) {
        isLight = light
        UserDefaults.standard.set(light ? "light" : "dark", forKey: Self.defaultsKey)
    }
}
