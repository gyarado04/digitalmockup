import SwiftUI

/// Point d'entrée de l'app.
@main
struct AgenceTemplate3DApp: App {
    @State private var appState = AppState()

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
