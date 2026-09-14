import Foundation

/// Espacements de TemplatePickerView, trouvés à la main via un panneau de
/// réglage temporaire (retiré le 2026-09-03, "retire les boutons de
/// panneau de contrôle" — chantier considéré clos) puis figés ici en dur,
/// comme le commentaire DEFAULTS de app/ui/spacing.py côté Python
/// l'annonçait : "rien à retirer du code une fois fait, le panneau peut
/// juste ne plus jamais être rouvert."
enum TemplatePickerSpacing {
    static let outerPadding: Double = 25
    static let headerToGridSpacing: Double = 20
    static let gridSpacing: Double = 16
    static let gridToDividerSpacing: Double = 45
    static let dividerToFooterSpacing: Double = 20
    static let cardTextPadding: Double = 12
}
