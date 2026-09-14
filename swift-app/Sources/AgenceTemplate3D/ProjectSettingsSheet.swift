import AgenceTemplate3DCore
import SwiftUI

/// Page "Paramètres" du projet (bouton engrenage, ProjectView) — demande
/// explicite du 2026-09-07 : "il faut quand même une page paramètres avec
/// les toggles dedans, mais quand on active le toggle, le choix des
/// couleurs sont dans le projet, donc l'utilisation se fait dans le projet
/// mais l'activation se fait dans la page paramètres".
///
/// N'affiche donc QUE l'interrupteur d'activation
/// (`Project.colorPickerEnabled`) — son contenu (color picker + aperçu)
/// vit dans `ProjectView.leftColumn`, pas ici.
///
/// Portait aussi un 2ème toggle, "Sections importantes"
/// (`Project.manualScrollEnabled`) — retiré ENTIÈREMENT le 2026-09-08 à la
/// demande explicite de l'utilisateur ("tu peux retirer le paramètre
/// section importante" → "retirer toute la fonctionnalité"), avec tout ce
/// qui allait avec (`ImportantSection`, `SectionEditorPanel.swift`/
/// `ScrollControlView.swift`, `AppState.assignCameraToSection`/
/// `addImportantSection`/etc., `camera_sections` côté rendu et
/// `camera_own_segment`/`camera_section_fraction` côté `headless.py`) —
/// voir mémoire projet pour l'historique complet de cette fonctionnalité
/// (plusieurs pivots de design le 2026-09-07 avant cet abandon).
struct ProjectSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Paramètres").font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }

            if let project = appState.project {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Couleurs personnalisées",
                        isOn: Binding(
                            get: { project.colorPickerEnabled },
                            set: { appState.setColorPickerEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    Text("Le color picker et l'aperçu apparaissent dans le projet.")
                        .font(.caption).dimText()
                }
            }

            Divider()

            // Rejoue la vidéo d'accueil à la demande — indépendant du
            // drapeau "déjà vue au lancement" (2026-09-08). `dismiss()`
            // D'ABORD : la vidéo est un overlay maison posé sur
            // ContentView (voir OnboardingVideoView.swift), sous la
            // fenêtre de cette VRAIE sheet système — sans fermer cette
            // sheet en premier, la vidéo s'afficherait DERRIÈRE elle,
            // invisible tant que "Paramètres" reste ouvert.
            Button {
                dismiss()
                appState.presentOnboardingVideo()
            } label: {
                Text("Voir la vidéo de présentation").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 260)
    }
}
