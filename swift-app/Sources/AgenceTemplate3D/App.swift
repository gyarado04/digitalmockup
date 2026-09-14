import Sparkle
import SwiftUI

/// Point d'entrée de l'app.
@main
struct AgenceTemplate3DApp: App {
    @State private var appState = AppState()

    /// Mises à jour automatiques (Sparkle, 2026-09-14, demande explicite —
    /// "sans qu'ils aient besoin de la réinstaller"). `let` simple (pas
    /// `@State`) : `SPUStandardUpdaterController` est une classe (référence
    /// stable), et ce `App` SwiftUI n'est instancié qu'une fois pour toute
    /// la vie du process — même pattern que documenté par Sparkle
    /// lui-même pour SwiftUI.
    ///
    /// `startingUpdater: false` (2026-09-14, bug réel) — essayé `true`
    /// d'abord en pensant l'échec silencieux/inoffensif (confirmé
    /// "inerte" via logs/réseau SUR CETTE machine de dev), mais sur un
    /// vrai lancement utilisateur ça affiche une popup d'erreur bloquante
    /// ("Unable to Check For Updates — The updater failed to start") : la
    /// Library Validation qui bloque Sparkle (voir README.md "Mises à
    /// jour automatiques") fait ÉCHOUER le démarrage de façon VISIBLE
    /// dans ce cas, pas juste un no-op silencieux comme observé ici.
    /// `false` : le contrôleur existe (prêt pour plus tard, un vrai
    /// certificat) mais NE DÉMARRE RIEN tout seul — aucune popup
    /// possible tant que rien ne l'invoque, et le menu "Rechercher les
    /// mises à jour…" est de toute façon déjà masqué (voir `.commands`
    /// plus bas).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )

    init() {
        AppFonts.registerBundledFonts()
        SelfTestRunner.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("DigitalMockup") {
            ContentView()
                .environment(appState)
        }
        // Barre de titre "intégrée" : plus de bandeau gris séparé avec le
        // titre — les ronds rouge/jaune/vert restent flottants en haut à
        // gauche, le contenu remonte jusqu'en haut de la fenêtre (voir
        // les marges ajoutées dans ContentView/ProjectView pour ne pas
        // passer dessous).
        .windowStyle(.hiddenTitleBar)
        // Taille de lancement — repère d'origine : la popup "Choisissez un
        // template" (TemplatePickerView) fait 740×560
        // (3×220 + 2×16 + 48, 560). `.defaultSize` fixe la taille
        // D'OUVERTURE seulement — l'utilisateur reste libre de
        // redimensionner plus grand ensuite (utile pour ProjectView, sa
        // disposition à 2 colonnes veut plus de place). DÉCOUPLÉE du
        // minimum (740×560, voir ContentView.swift `minWidth`/
        // `minHeight`, toujours aligné sur TemplatePickerView) : la
        // fenêtre s'ouvre plus grande que ce minimum, ce qui est valide
        // (`idealWidth`/`idealHeight` > `minWidth`/`minHeight`). IMPORTANT :
        // `ContentView.swift` a aussi `idealWidth`/`idealHeight` sur son
        // `.frame()` racine — DOIT rester synchronisé avec ces valeurs (voir
        // son commentaire "bug réel" du 2026-09-11 : sans taille idéale
        // explicite alignée sur `.defaultSize`, la fenêtre s'ouvre bien
        // plus grande que prévu, ignorant `.defaultSize`). 1000×750 →
        // 1300×750 le 2026-09-11 (valeur trouvée via le panneau de debug
        // largeur/hauteur, "Copier les valeurs" : "1300 × 750").
        .defaultSize(width: 1300, height: 750)
        // Remplace "Nouvelle fenêtre" (par défaut dans le menu Fichier
        // généré automatiquement) par les entrées de main_window.py:
        // _build_menu — cette app est mono-fenêtre, "Nouvelle fenêtre"
        // n'aurait aucun sens ici.
        .commands {
            // Entrée de menu "Rechercher les mises à jour…" MASQUÉE le
            // 2026-09-14 (demande explicite) — tant que l'app n'a qu'une
            // signature ad-hoc, Sparkle ne peut de toute façon rien
            // trouver (voir README.md "Mises à jour automatiques" —
            // Library Validation du runtime durci bloque
            // Sparkle.framework sans un vrai certificat Developer ID) :
            // un bouton qui ne fait rien de visible aurait juste
            // dérouté un collègue curieux. `updaterController` reste
            // actif en arrière-plan (inoffensif, confirmé inerte) —
            // pour réactiver ce menu le jour où un vrai certificat est
            // disponible, redécommenter ce `CommandGroup` :
            //
            // CommandGroup(after: .appInfo) {
            //     Button("Rechercher les mises à jour…") {
            //         updaterController.checkForUpdates(nil)
            //     }
            // }
            CommandGroup(replacing: .newItem) {
                Button("Nouveau projet depuis un template…") { appState.showTemplatePicker = true }
                Button("Ouvrir un fichier .blend existant…") { appState.presentOpenBlendPanel() }
                Divider()
                Button("Enregistrer") { appState.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(appState.project == nil)
                Divider()
                Button("Changer l'emplacement des projets…") { appState.presentChangeProjectsRootPanel() }
            }
        }
        // Panneaux de réglage des espacements (TemplatePickerView/
        // ProjectView) retirés le 2026-09-03 sur demande explicite ("retire
        // les boutons de panneau de contrôle") — les valeurs trouvées via
        // ces panneaux restent en dur dans TemplatePickerSpacing.swift/
        // ProjectViewSpacing.swift, chantier considéré clos.
    }
}
