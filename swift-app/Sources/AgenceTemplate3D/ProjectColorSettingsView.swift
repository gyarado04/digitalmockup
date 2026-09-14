import AgenceTemplate3DCore
import AppKit
import SwiftUI

/// Couleurs personnalisées — propre à CE projet (voir
/// `Project.colorPickerEnabled`), vit directement dans la colonne de
/// gauche sous son toggle (PAS dans une fenêtre "Paramètres" séparée : les
/// Paramètres sont pour toute l'app, pas pour un réglage par projet —
/// demande explicite du 2026-09-07, corrige un premier essai en sheet
/// modale). Un seul color picker natif pour l'instant (Fond) + un bouton
/// "Aperçu" qui déclenche un vrai rendu Blender (1 frame, réglages TEST)
/// pour voir à quoi ça ressemble avant de lancer un rendu complet.
///
/// Le color picker "Tablette/téléphone" (matériau "Noir basic") a été
/// RETIRÉ de l'UI — demande explicite du 2026-09-07 : dans ce template, ce
/// matériau colore toute la tranche visible du cadre, pas juste les
/// boutons (aucune séparation de matériau dédiée aux boutons seuls), donc
/// on laisse cette possibilité de côté pour l'instant plutôt que de
/// livrer un réglage qui ne fait pas ce que son nom suggère. Le code
/// Core/Blender (`Project.deviceColorHex`, `apply_color_override(["Noir
/// basic"], …)`) reste en place, juste jamais renseigné depuis l'UI —
/// facile à rebrancher si un matériau boutons dédié est ajouté au
/// template plus tard.
struct ProjectColorSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette

    /// Couleur par défaut du template "tablette" (matériau "Fond",
    /// inspectée directement dans le .blend) — juste une valeur de repli
    /// plausible pour le picker tant que l'utilisateur n'a rien choisi,
    /// PAS une valeur réellement appliquée (`nil` côté Project = garder la
    /// couleur d'origine du template, voir headless.py).
    private static let defaultBackground = Color(red: 0.24, green: 0.24, blue: 0.24)

    var body: some View {
        if let project = appState.project {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Couleur du fond :").dimText()
                    NativeColorSwatch(
                        color: Binding(
                            get: { Color(hex: project.backgroundColorHex) ?? Self.defaultBackground },
                            set: { appState.setBackgroundColorHex($0.toHexString()) }
                        ),
                        label: "Fond"
                    )
                    .frame(width: 28, height: 20)
                    Spacer()
                    // Valide et referme cette SECTION (le panneau "Couleurs
                    // personnalisées" dans le projet) — PAS le panneau
                    // système `NSColorPanel` (tentatives précédentes sur ce
                    // dernier abandonnées, mauvaise cible : l'utilisateur
                    // voulait fermer ce panneau-ci, celui de l'app, pas
                    // celui de macOS — clarifié explicitement le
                    // 2026-09-07). Repasse simplement le toggle "Couleurs
                    // personnalisées" à `false`, exactement comme si
                    // l'utilisateur l'avait désactivé lui-même dans
                    // Paramètres.
                    Button {
                        appState.setColorPickerEnabled(false)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Valider la couleur et fermer le panneau")
                }

                Button {
                    appState.previewColors(background: project.backgroundColorHex, device: nil)
                } label: {
                    HStack {
                        if appState.isGeneratingColorPreview {
                            ProgressView().controlSize(.small)
                        }
                        Text(appState.isGeneratingColorPreview ? "Génération de l'aperçu…" : "Aperçu").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(appState.isGeneratingColorPreview)

                if let error = appState.colorPreviewError {
                    Text(error).font(.caption).foregroundStyle(palette.warning)
                }

                previewBox
            }
            .padding(14)
            .panelBackground(cornerRadius: 14, dashed: true)
        }
    }

    /// Même idiome que RenderPreviewPanel.previewBox (16:9 letterbox,
    /// jamais déformé) — un vrai rendu Blender à chaque clic sur
    /// "Aperçu", écrit dans un fichier temporaire à chemin UNIQUE (UUID,
    /// voir AppState.previewColors) donc toujours réaffiché à jour ici,
    /// jamais une image en cache périmée.
    @ViewBuilder
    private var previewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(palette.surface)
            if let path = appState.colorPreviewPath, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if !appState.isGeneratingColorPreview {
                Text("Clique sur \"Aperçu\" pour voir un rendu avec ces couleurs.")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .foregroundStyle(palette.textDim)
                    .padding()
            }
        }
        .aspectRatio(1920.0 / 1080.0, contentMode: .fit)
    }
}
