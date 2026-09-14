import AgenceTemplate3DCore
import AppKit
import AVKit
import SwiftUI

/// Enveloppe AppKit de `AVPlayerView` (PAS `SwiftUI.VideoPlayer`, voir
/// commentaire de `OnboardingVideoView` plus bas — `VideoPlayer` plante
/// au runtime dans cet exécutable SwiftPM). Même idiome que `WKWebView`
/// ailleurs dans ce projet : contrôles de lecture natifs inclus
/// (`controlsStyle`).
private struct AVPlayerNSView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Vidéo de présentation ("comment fonctionne l'app") — montrée à
/// l'ouverture de l'app (une fois, sauf case "Ne plus afficher à
/// l'ouverture" cochée) ET rejouable à la demande depuis Paramètres
/// ("Voir la vidéo de présentation", `ProjectSettingsSheet`). Demande
/// explicite du 2026-09-08 ; mise en page reprise d'une capture d'écran
/// fournie par l'utilisateur : grand popup centré (titre + description
/// centrés, vidéo en grand), croix de fermeture, case à cocher flottante
/// en bas à droite — PAS des boutons "Fermer"/"Ne plus afficher" classiques
/// comme dans un premier essai.
///
/// Overlay maison (pas une vraie `.sheet` système) — même raison que
/// `TemplatePickerView`/`ShotPickerView` (voir `ContentView.swift`) :
/// une sheet AppKit assombrit toute la fenêtre porteuse de façon non
/// contrôlable depuis SwiftUI, effet déjà rejeté par l'utilisateur pour
/// ces 2 autres popups. Mêmes 3 façons de fermer qu'eux : croix, clic sur
/// le scrim (géré dans `ContentView.swift`), Échap.
///
/// Lecture vidéo via `AVPlayerNSView` (enveloppe `NSViewRepresentable`
/// autour d'`AVKit.AVPlayerView`, AppKit) — PAS `SwiftUI.VideoPlayer` :
/// essayé d'abord, plantait AU LANCEMENT (`EXC_CRASH`/`SIGABRT`, fatal
/// error Swift profondément dans la résolution de métadonnées génériques
/// — `swift_getTypeByMangledName`/`getSuperclassMetadata`) dans cet
/// exécutable SwiftPM, constaté le 2026-09-08 via le rapport de crash
/// (`~/Library/Logs/DiagnosticReports/`). `AVPlayerView` (le composant
/// AppKit historique, plus stable) contourne le problème — même famille
/// de solution que `WKWebView` ailleurs dans ce projet (une vue AppKit
/// enveloppée plutôt que son équivalent déclaratif SwiftUI).
///
/// `onboarding_video.mp4` (déclarée dans `Package.swift`) est la VRAIE
/// vidéo de présentation, fournie par l'utilisateur le 2026-09-11
/// (remplace le placeholder ffmpeg — simple fond de couleur — utilisé
/// jusque-là). Remplacement par simple copie du fichier, même nom/dossier
/// `Resources/`, sans toucher `Package.swift` — seul le ratio d'affichage
/// (`.aspectRatio` plus bas) a dû être ajusté pour coller aux vraies
/// dimensions (1200×674, mesurées via ffprobe) au lieu du 1200×800
/// provisoire. Titre/description toujours écrits en dur (pas de piste
/// audio ni de texte à synchroniser dans cette vidéo).
///
/// Marges/spacings ci-dessous réglés le 2026-09-11 via un panneau de
/// debug temporaire (sliders + "Copier les valeurs") — RETIRÉ une fois
/// les valeurs validées ("c'est bon on valide" / "enlève les restes de
/// dev"), même pattern déjà appliqué le 2026-09-03 à
/// `TemplatePickerSpacing`/`ProjectViewSpacing` : le panneau ne sert qu'à
/// TROUVER les valeurs, pas à rester dans le code une fois qu'elles sont
/// figées.
struct OnboardingVideoView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    @State private var player: AVPlayer?
    /// Plafond de hauteur du popup ENTIER — passé par `ContentView`
    /// (même budget que `ShotPickerView`, `popupMaxHeight`, calculé
    /// depuis la vraie hauteur de fenêtre). Bug réel corrigé le
    /// 2026-09-09 ("il faut la marge peu importe la dimension de la
    /// fenêtre") : sans plafond, cette carte pouvait devenir plus haute
    /// que la fenêtre sur un petit écran — la marge basse (`.padding(40)`)
    /// n'était alors PAS préservée, elle se faisait juste manger par le
    /// débordement, quoi que je change à l'intérieur de la zone vidéo.
    /// Avec ce plafond, c'est la zone vidéo (seule partie flexible) qui
    /// rétrécit en premier — le titre, la description, la case à cocher
    /// et les 2 marges (haut ET bas) restent, eux, TOUJOURS entiers.
    let maxHeight: CGFloat

    /// Même principe que `maxHeight`, en LARGEUR — passé par `ContentView`
    /// (`popupMaxWidth`, calculé depuis la vraie largeur de fenêtre).
    /// Bug réel corrigé le 2026-09-11 ("trop petit et du coup il y a pas
    /// de marge") : `.frame(maxWidth: cardMaxWidth)` seul ne plafonne
    /// qu'un MAXIMUM (900) — sur une fenêtre plus étroite que ça (740 au
    /// minimum), la zone vidéo (une `GeometryReader`, intrinsèquement
    /// "gourmande" : elle s'étire toujours pour remplir tout ce qu'on lui
    /// propose) tire la carte entière jusqu'aux bords de la fenêtre, zéro
    /// marge latérale — même mécanisme que le bug de marge verticale du
    /// 2026-09-09, en largeur cette fois. Combiné à `cardMaxWidth` via
    /// `min(...)` dans `.frame(maxWidth:)` plus bas : quelle que soit la
    /// taille de fenêtre, la carte ne dépasse JAMAIS ni 900pt (le design
    /// voulu) ni `maxWidth` (la fenêtre moins la marge réservée).
    let maxWidth: CGFloat

    // MARK: - Marges/spacings (valeurs finales, verrouillées le 2026-09-11)

    private static let outerPadding: CGFloat = 40
    private static let vstackSpacing: CGFloat = 20
    private static let cardMaxWidth: CGFloat = 900
    /// Place à laisser à tout ce qui n'est PAS la vidéo (2 × padding,
    /// titre, descriptions, espacements, case à cocher) pour que le
    /// popup entier ne dépasse jamais `maxHeight` — estimation
    /// volontairement généreuse (mieux vaut une vidéo un peu plus petite
    /// que prévu qu'une marge basse mangée), même esprit que
    /// `ShotPickerView.chromeHeight`. En dessous de ~180-200, la vidéo
    /// n'est plus limitée par la HAUTEUR mais par la LARGEUR de la carte
    /// (`cardMaxWidth` - 2×`outerPadding`) — elle affiche déjà sa taille
    /// maximale pour cette largeur, réduire ce budget plus bas n'a plus
    /// aucun effet visible (confirmé par l'utilisateur : "je peux pas
    /// aller plus bas ça fait rien").
    private static let chromeHeight: CGFloat = 200
    private static let overlayPadding: CGFloat = 15
    private static let overlaySpacing: CGFloat = 12

    private var videoMaxHeight: CGFloat {
        max(120, maxHeight - Self.chromeHeight)
    }

    var body: some View {
        VStack(spacing: Self.vstackSpacing) {
            Text("Fonctionnement de l'application")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Un aperçu rapide de l'app : capturer une page, assigner des plans, lancer un rendu.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .dimText()

            // Hauteur imposée EXPLICITEMENT depuis la largeur réelle
            // (`GeometryReader`), PAS un simple `.aspectRatio(fit)` sur le
            // `Group` — bug réel corrigé le 2026-09-09 ("il y a de la
            // marge en haut et pas en bas") : `AVPlayerView` (vue AppKit,
            // voir `AVPlayerNSView`) ne respecte pas fiablement le calcul
            // `.aspectRatio` de SwiftUI une fois enveloppée en
            // `NSViewRepresentable` — elle se dimensionnait plus haute que
            // prévu, poussant la case à cocher vers le bas et mangeant la
            // marge basse de `.padding(40)` sans toucher la marge haute.
            // `GeometryReader` fixe une hauteur en dur (`width × 800/1200`)
            // que la vue AppKit ne peut plus renégocier.
            GeometryReader { geo in
                Group {
                    if let player {
                        AVPlayerNSView(player: player)
                    } else {
                        // Ressource introuvable (ne devrait pas arriver, le
                        // placeholder est bundlé — voir Package.swift) :
                        // dégrade proprement plutôt que de planter ou de
                        // montrer une zone vide sans explication.
                        RoundedRectangle(cornerRadius: 8)
                            .fill(palette.surface)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "video.slash")
                                        .font(.system(size: 24))
                                        .foregroundStyle(palette.textDim)
                                    Text("Vidéo indisponible").font(.caption).dimText()
                                }
                            }
                    }
                }
                // `geo.size` DIRECTEMENT (pas recalculé depuis 800/1200) :
                // une fois `videoMaxHeight` atteint juste en dessous, la
                // largeur RÉELLE rétrécit aussi (aspectRatio(fit) contraint
                // par la hauteur, pas seulement par la largeur) — recalculer
                // depuis `geo.size.width` seul aurait redonné une hauteur
                // trop grande, exactement le bug déjà rencontré.
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            // 1200×674 — dimensions RÉELLES de la vraie vidéo fournie le
            // 2026-09-11 (mesurées via ffprobe), quasi du 16:9 (674 au lieu
            // de 675) plutôt que le 3:2 (1200×800) d'abord annoncé le
            // 2026-09-08 pour le placeholder — ratio exact repris ici pour
            // qu'`AVPlayerView` n'ajoute aucune bande de lettterbox/pillarbox
            // qu'elle ne gère pas déjà elle-même. `.frame(maxHeight:)`
            // ENSUITE : plafonne la hauteur AVANT que `GeometryReader` ne la
            // mesure — c'est ce qui garantit que la marge basse survit
            // sur une petite fenêtre (voir doc de `maxHeight` plus haut).
            .aspectRatio(1200.0 / 674.0, contentMode: .fit)
            .frame(maxHeight: videoMaxHeight)

            // Case à cocher, DANS la carte (demande explicite du
            // 2026-09-08 : un 1er essai la faisait flotter en dehors du
            // coin bas-droit, comme sur la capture d'écran d'origine —
            // finalement pas ce qui était voulu). INDÉPENDANTE de la
            // fermeture du popup (voir
            // AppState.suppressOnboardingVideoOnLaunch) : cochée, elle
            // mémorise tout de suite le choix SANS fermer le popup —
            // l'utilisateur ferme séparément (croix/clic scrim/Échap).
            HStack {
                Spacer()
                Toggle(
                    "Ne plus afficher à l'ouverture",
                    isOn: Binding(
                        get: { appState.suppressOnboardingVideoOnLaunch },
                        set: { appState.suppressOnboardingVideoOnLaunch = $0 }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }
        }
        .padding(Self.outerPadding)
        .frame(maxWidth: min(Self.cardMaxWidth, maxWidth))
        // Deuxième filet de sécurité sur le popup ENTIER (en plus du
        // plafond posé sur la vidéo via `videoMaxHeight`) : si jamais
        // `chromeHeight` sous-estime la vraie place prise par le
        // titre/la description/la case à cocher, ce `.frame(maxHeight:)`
        // garantit quand même que le popup ne déborde JAMAIS de la
        // fenêtre — même filet que `ShotPickerView`.
        .frame(maxHeight: maxHeight)
        .modalCardBackground()
        // Croix de fermeture + téléchargement — coin haut-droit du
        // popup, par-dessus le VStack centré ci-dessus plutôt qu'à
        // l'intérieur (sinon ça pousserait le titre hors du centre).
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Self.overlaySpacing) {
                Button {
                    appState.downloadOnboardingVideo()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18))
                        .foregroundStyle(palette.textDim)
                }
                .buttonStyle(.plain)
                .help("Télécharger la vidéo")

                Button {
                    appState.closeOnboardingVideo()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.textDim)
                }
                .buttonStyle(.plain)
                .help("Fermer")
            }
            .padding(Self.overlayPadding)
        }
        .onAppear {
            guard player == nil else { return }
            if let url = Bundle.module.url(forResource: "onboarding_video", withExtension: "mp4") {
                let newPlayer = AVPlayer(url: url)
                player = newPlayer
                newPlayer.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
