import AppKit
import CoreText
import SwiftUI

/// Police maison (design fourni par l'utilisateur, 2026-09-02) — embarquée
/// dans le paquet (`Resources/`, voir Package.swift) et enregistrée ICI au
/// lancement, plutôt que d'exiger qu'elle soit installée sur le Mac de
/// l'utilisateur final. `registerBundledFonts()` doit être appelée une
/// fois, tôt (App.swift:init(), avant tout rendu SwiftUI) — un
/// enregistrement en double est sans risque (CTFontManager l'ignore),
/// donc pas besoin de garde-fou "déjà fait".
enum AppFonts {
    /// Nom PostScript exact du fichier embarqué — vérifié avec CoreText
    /// (`CTFontCopyPostScriptName`), pas deviné depuis le nom de fichier
    /// (les deux ne coïncident pas toujours).
    static let monumentGroteskRegular = "MonumentGrotesk-Regular"

    static func registerBundledFonts() {
        guard let url = Bundle.module.url(forResource: "MonumentGrotesk-Regular", withExtension: "otf") else {
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}

extension Font {
    /// Monument Grotesk Regular — retombe silencieusement sur la police
    /// système si jamais l'enregistrement a échoué (mieux qu'un crash ou
    /// du texte invisible).
    static func monumentGrotesk(_ size: CGFloat) -> Font {
        .custom(AppFonts.monumentGroteskRegular, size: size)
    }
}

/// Portage du thème Qt de l'app Python (app/ui/theme.py) — MÊMES couleurs
/// exactes (DARK_PALETTE/LIGHT_PALETTE), traduites en jetons SwiftUI.
///
/// Différence assumée avec Python : là-bas le thème est un bouton explicite
/// (Qt ne suit pas nativement l'apparence système de façon fiable) ; ici on
/// suit l'apparence système standard de macOS via `colorScheme`, plus
/// idiomatique côté SwiftUI — pas de bouton dédié pour l'instant (à ajouter
/// si l'utilisateur le demande explicitement).
struct AppPalette: Equatable {
    var background: Color
    var surface: Color
    var surfaceHover: Color
    var border: Color
    var text: Color
    var textDim: Color
    var accent: Color
    var accentHover: Color
    var warning: Color
    var panelBackground: Color
    var modalBackground: Color

    static let dark = AppPalette(
        background: Color(hex: 0x111113),
        surface: Color(hex: 0x1c1c1e),
        surfaceHover: Color(hex: 0x28282a),
        border: Color(hex: 0x2c2c2e),
        text: Color(hex: 0xf2f2f2),
        textDim: Color(hex: 0x8e8e93),
        accent: Color(hex: 0x3b82f6),
        accentHover: Color(hex: 0x2f6fe0),
        warning: Color(hex: 0xd29922),
        panelBackground: Color(hex: 0x17171a),
        // #111113 (pas #1c1c1e comme theme.py côté Python) : demandé
        // explicitement même que le fond général — la popup "Choisissez
        // un template" doit se fondre dans la fenêtre, pas se détacher en
        // panneau plus clair.
        modalBackground: Color(hex: 0x111113)
    )

    static let light = AppPalette(
        background: Color(hex: 0xf5f5f7),
        surface: Color(hex: 0xffffff),
        surfaceHover: Color(hex: 0xe8e8ec),
        border: Color(hex: 0xd1d1d6),
        text: Color(hex: 0x1c1c1e),
        textDim: Color(hex: 0x6e6e73),
        accent: Color(hex: 0x3b82f6),
        accentHover: Color(hex: 0x2f6fe0),
        warning: Color(hex: 0xb8860b),
        panelBackground: Color(hex: 0xeeeef0),
        modalBackground: Color(hex: 0xffffff)
    )

    static func forColorScheme(_ scheme: ColorScheme) -> AppPalette {
        scheme == .dark ? .dark : .light
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

private struct AppPaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette.dark
}

extension EnvironmentValues {
    var appPalette: AppPalette {
        get { self[AppPaletteKey.self] }
        set { self[AppPaletteKey.self] = newValue }
    }
}

/// À poser une fois en haut de la hiérarchie (ContentView) : calcule la
/// palette depuis l'apparence système et l'injecte pour tous les
/// descendants, + peint le fond de fenêtre (QMainWindow { background }).
struct ThemedRoot<Content: View>: View {
    /// PAS `@Environment(\.colorScheme)` : le thème de l'app est un choix
    /// explicite de l'utilisateur (voir ThemePreference.swift), indépendant
    /// de l'apparence système macOS — même comportement que côté Python
    /// (QSettings "theme_mode", ne suit jamais le système).
    private var themePreference = ThemePreference.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        let palette = AppPalette.forColorScheme(themePreference.isLight ? .light : .dark)
        content()
            .environment(\.appPalette, palette)
            // Force aussi l'apparence des CONTRÔLES SYSTÈME (Toggle,
            // TextField, etc.) à suivre ce même choix, plutôt que de les
            // laisser suivre le système pendant que le reste de l'app
            // (couleurs maison) suit `themePreference` — sinon incohérent
            // si le mode choisi ici diffère du mode système.
            .preferredColorScheme(themePreference.isLight ? .light : .dark)
            .background(palette.background)
            // La fenêtre AppKit elle-même a sa propre couleur de fond,
            // séparée du contenu SwiftUI dessiné par-dessus — avec
            // .windowStyle(.hiddenTitleBar) (App.swift), un résidu de
            // cette couleur peut apparaître brièvement sur les bords/
            // coins (redimensionnement, zones que le contenu ne couvre
            // pas encore le temps d'un layout). Fixée explicitement au
            // fond du thème pour ne jamais laisser voir une autre teinte.
            .background(WindowBackgroundAccessor(color: NSColor(palette.background)))
    }
}

/// Accès à la NSWindow porteuse pour fixer sa `backgroundColor` — pas
/// d'équivalent SwiftUI pur pour ça.
private struct WindowBackgroundAccessor: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.backgroundColor = color }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.backgroundColor = color
    }
}

// ── boutons — portage de QPushButton/QPushButton#primary ──

/// QPushButton#primary : fond accent, texte blanc, pas de bordure.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // AUCUN `.font`/`.fontWeight` ici : hérite tel quel de la
            // police posée par l'appelant (ex. `.monumentGrotesk`, un
            // seul poids "Regular" embarqué — voir Theme.swift:AppFonts).
            // Un `.fontWeight(.semibold)` ici forçait macOS à FAUX-gras
            // synthétique cette police (aucun vrai poids semibold
            // embarqué), rendu visiblement différent + hauteur de bouton
            // différente de Secondary (bug constaté). Primary/Secondary
            // se distinguent par la COULEUR seule (accent vs surface),
            // pas par le poids du texte — cohérent avec la maquette.
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minWidth: 0)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(!isEnabled ? palette.surface : (configuration.isPressed ? palette.accentHover : palette.accent))
            )
            .foregroundStyle(isEnabled ? .white : palette.textDim)
    }
}

/// QPushButton normal : surface + bordure, hover/pressed plus sombre.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.appPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? palette.border : palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
            .foregroundStyle(isEnabled ? palette.text : palette.textDim)
    }
}

/// QPushButton "destructive" — même forme que Secondary, texte/bordure en
/// rouge système (pas de rouge dédié côté theme.py, macOS a déjà un rouge
/// destructif standard qu'on réutilise tel quel).
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.appPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? palette.border : palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.red.opacity(0.55), lineWidth: 1)
            )
            .foregroundStyle(Color.red)
    }
}

// ── fonds — portage de QFrame#card / #panel / #pageBox / #modalCard ──

extension View {
    /// QFrame#card — cartes de la grille de sélection (rayon 14, surface,
    /// pas de bordure, léger éclaircissement au survol laissé aux appelants
    /// via `.hoverEffect`/état local, cf. card_grid.py).
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(PaletteBackgroundModifier(cornerRadius: cornerRadius, kind: .card))
    }

    /// QFrame#panel / #pageBox — panneaux "enfoncés" (boîte de mise en
    /// place, boîte d'une page). `dashed: true` pour le style pointillé de
    /// #pageBox (une page).
    func panelBackground(cornerRadius: CGFloat = 12, dashed: Bool = false) -> some View {
        modifier(PaletteBackgroundModifier(cornerRadius: cornerRadius, kind: .panel(dashed: dashed)))
    }

    /// QFrame#modalCard — carte centrée d'un panneau superposé (écran
    /// d'accueil, sélecteur de template).
    func modalCardBackground(cornerRadius: CGFloat = 16) -> some View {
        modifier(PaletteBackgroundModifier(cornerRadius: cornerRadius, kind: .modal))
    }

    /// QFrame#shotChip — puce d'un plan déjà assigné.
    func chipBackground(cornerRadius: CGFloat = 10) -> some View {
        modifier(PaletteBackgroundModifier(cornerRadius: cornerRadius, kind: .chip))
    }
}

private enum BackgroundKind {
    case card
    case panel(dashed: Bool)
    case modal
    case chip
}

private struct PaletteBackgroundModifier: ViewModifier {
    @Environment(\.appPalette) private var palette
    let cornerRadius: CGFloat
    let kind: BackgroundKind

    func body(content: Content) -> some View {
        let fill: Color
        switch kind {
        case .card, .chip: fill = palette.surface
        case .panel: fill = palette.panelBackground
        case .modal: fill = palette.modalBackground
        }
        return content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(fill))
            .overlay(border)
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .panel(dashed: true):
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .panel, .modal, .chip:
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(palette.border, lineWidth: 1)
        case .card:
            EmptyView()
        }
    }
}

// ── texte — portage de QLabel[role=...] ──

extension View {
    /// QLabel[role="dim"] — texte secondaire (sous-titres, légendes).
    func dimText() -> some View {
        modifier(DimTextModifier())
    }
}

private struct DimTextModifier: ViewModifier {
    @Environment(\.appPalette) private var palette
    func body(content: Content) -> some View {
        content.foregroundStyle(palette.textDim)
    }
}

// ── champ de texte — portage de QLineEdit (soulignement seul, pas de
// bordure complète ; accent au focus). Un modificateur plutôt qu'un vrai
// TextFieldStyle : l'API publique de TextFieldStyle personnalisé reste
// incomplète côté SwiftUI/AppKit (méthode `_body` soulignée, non garantie
// stable) — un ViewModifier ordinaire fait la même chose sans ce risque.

extension View {
    func underlineFieldStyle() -> some View {
        modifier(UnderlineFieldModifier())
    }
}

private struct UnderlineFieldModifier: ViewModifier {
    @Environment(\.appPalette) private var palette
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.vertical, 6)
            .focused($isFocused)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused ? palette.accent : palette.border)
                    .frame(height: isFocused ? 2 : 1)
            }
    }
}
