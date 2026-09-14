import AgenceTemplate3DCore
import AppKit
import SwiftUI

/// Écran principal — juste assez pour un flux bout-en-bout fonctionnel
/// (créer un projet, assigner des plans, capturer une page, lancer un
/// rendu). Thème (Theme.swift) posé ici, une seule fois, pour toute la
/// hiérarchie — portage des couleurs exactes de app/ui/theme.py.
struct ContentView: View {
    @Environment(AppState.self) private var appState

    /// Nombre max de lignes affichées sous "Anciens projets" (en plus des
    /// 3 cartes de "Projets récents") — au-delà, le lien "Voir tout" ouvre
    /// le dossier complet dans le Finder plutôt que de tout lister ici.
    /// 2026-09-08, demande explicite de l'utilisateur ; 6 = nombre exact
    /// de lignes visibles sur la maquette Figma définitive fournie le
    /// même jour.
    fileprivate static let olderProjectsLimit = 6

    var body: some View {
        ThemedRoot {
            Group {
                if appState.project != nil {
                    ProjectView()
                } else {
                    landing
                }
            }
            // 740×560 : même taille que la popup "Choisissez un template"
            // (voir App.swift:.defaultSize) — la fenêtre peut s'ouvrir à
            // exactement cette taille sans être forcée plus grande.
            // L'utilisateur reste libre d'agrandir ensuite pour la
            // disposition à 2 colonnes de ProjectView (page/plans à
            // gauche + aperçu du rendu à droite, comme main_window.py —
            // voir ProjectView.swift). maxWidth/maxHeight .infinity : sans
            // ça, le contenu reste à sa taille minimale dans un coin si la
            // fenêtre est agrandie, laissant voir le fond de fenêtre macOS
            // par défaut tout autour (pas le fond du thème) —
            // ThemedRoot.background() ne peint que derrière la taille
            // RÉELLE de ce contenu.
            //
            // `idealWidth`/`idealHeight` AJOUTÉS le 2026-09-11 — bug réel
            // constaté ("il faut réduire la largeur de l'app au
            // lancement", confirmé en lisant directement le fichier de
            // préférences sur disque juste après un lancement bien FRAIS,
            // sans AUCUN état sauvegardé) : `.defaultSize(...)` dans
            // App.swift n'était PAS respecté — la fenêtre s'ouvrait à
            // ~1512×726 (environ 79%/69% de la taille de l'écran). Cause :
            // sans `idealWidth`/`idealHeight`, ce `.frame()` n'a qu'un
            // minimum et un maximum INFINI, donc AUCUNE taille "idéale"
            // concrète pour la mise en page racine — AppKit/SwiftUI, dans
            // ce flou, retombe sur une heuristique basée sur l'écran plutôt
            // que sur `.defaultSize`. Poser une taille idéale explicite ICI
            // (qui correspond exactement à `.defaultSize`) donne à la mise
            // en page racine une taille concrète à annoncer à la fenêtre —
            // vérifié en effaçant la clé "NSWindow Frame …" ET en confirmant
            // qu'elle ne revenait PAS à une valeur différente au lancement
            // suivant. `idealWidth`/`idealHeight` = 1300/750 (2026-09-11,
            // valeur trouvée via le panneau de debug largeur/hauteur —
            // 1000/750 au départ) — DOIT rester synchronisé avec
            // `App.swift:.defaultSize`, voir son commentaire. `minWidth`/
            // `minHeight` restent 740/560 (inchangés, alignés sur
            // TemplatePickerView) : la fenêtre s'ouvre plus grande que ce
            // plancher, ce qui est valide.
            .frame(minWidth: 740, idealWidth: 1300, maxWidth: .infinity, minHeight: 560, idealHeight: 750, maxHeight: .infinity)
            // Overlay maison plutôt qu'une vraie `.sheet` système — une
            // sheet AppKit assombrit automatiquement toute la fenêtre
            // porteuse et grise ses boutons de fermeture/agrandissement
            // pendant qu'elle est ouverte (constaté par l'utilisateur :
            // "la couleur de la première page change"), effet qu'on ne
            // contrôle pas depuis SwiftUI. Portage du pattern
            // OverlayDialog côté Python (fond assombri DESSINÉ, pas la
            // fenêtre elle-même qui change) : le fond du thème reste
            // rigoureusement identique, seul ce scrim + la carte
            // s'affichent par-dessus.
            .overlay {
                // GeometryReader : donne la hauteur RÉELLE de la fenêtre à
                // cet instant, pour plafonner la hauteur de ShotPickerView
                // (voir `popupMaxHeight` plus bas) — sans ça, un popup avec
                // beaucoup de contenu (plusieurs catégories de plans) peut
                // être plus haut que la fenêtre elle-même et déborder, une
                // partie (le haut, souvent) rendue hors de la zone visible
                // — bug constaté par l'utilisateur le 2026-09-03 sur
                // "Assigner un plan" avec beaucoup de plans.
                // TemplatePickerView n'en a pas besoin : son contenu (5
                // presets) tient toujours largement dans la fenêtre
                // minimale (740×560), pas la peine de risquer de perturber
                // son dimensionnement déjà réglé finement.
                GeometryReader { geo in
                    let popupMaxHeight = min(max(geo.size.height - 80, 360), 640)
                    // Même principe que `popupMaxHeight`, mais en LARGEUR —
                    // ajouté le 2026-09-11 pour `OnboardingVideoView`
                    // seulement (bug réel : "trop petit et du coup il y a
                    // pas de marge", capture fournie par l'utilisateur sur
                    // la fenêtre par défaut 740×560). Contrairement à
                    // `TemplatePickerView`/`ShotPickerView` (largeur FIXE,
                    // jamais de problème), `OnboardingVideoView` contient
                    // une `GeometryReader` interne (zone vidéo) qui s'étire
                    // TOUJOURS pour remplir toute la largeur qu'on lui
                    // propose — sans ce plafond, `.frame(maxWidth: 900)`
                    // seul ne réserve aucune marge latérale : sur une
                    // fenêtre plus étroite que 900 (le minimum de l'app est
                    // 740), la carte allait jusqu'aux bords de la fenêtre.
                    // Pas de plafond haut ici (900 déjà imposé par
                    // `OnboardingVideoView.cardMaxWidth`) : seulement la
                    // réservation basse, mêmes 80pt que la hauteur (40 de
                    // marge de chaque côté).
                    let popupMaxWidth = max(geo.size.width - 80, 360)
                    if appState.showOnboardingVideo {
                        // Même overlay maison + mêmes 3 façons de fermer
                        // que les 2 popups suivants (croix dans le popup,
                        // clic sur le scrim, Échap) — design revu le
                        // 2026-09-08 (capture d'écran fournie par
                        // l'utilisateur) : grand popup centré, "Ne plus
                        // afficher" devient une case à cocher séparée
                        // (voir OnboardingVideoView), plus un bouton qui
                        // ferme ET mémorise en même temps.
                        ZStack {
                            Color.black.opacity(0.45)
                                .ignoresSafeArea()
                                .onTapGesture { appState.closeOnboardingVideo() }
                            OnboardingVideoView(maxHeight: popupMaxHeight, maxWidth: popupMaxWidth)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .onExitCommand { appState.closeOnboardingVideo() }
                    } else if appState.showTemplatePicker {
                        ZStack {
                            // Scrim dessiné à la main derrière le popup —
                            // opacité 45% (ajustée depuis la valeur d'origine
                            // de OverlayDialog côté Python, `rgba(0,0,0,165)`
                            // ≈ 65%, jugée trop sombre). Distinct de la sheet
                            // SYSTÈME de macOS (qui assombrit toute la
                            // fenêtre, effet non désiré, non réglable) — ce
                            // scrim-ci ne couvre que la zone du popup, sous
                            // contrôle complet.
                            Color.black.opacity(0.45)
                                .ignoresSafeArea()
                                .onTapGesture { appState.showTemplatePicker = false }
                            TemplatePickerView()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        // Échap pour fermer sans choisir, même que le clic à
                        // l'extérieur — parité avec OverlayDialog côté Python.
                        .onExitCommand { appState.showTemplatePicker = false }
                    } else if let pageIndex = appState.shotPickerPageIndex {
                        // Même overlay maison que TemplatePickerView (voir juste
                        // au-dessus) — "Assigner un plan" passe d'un `.popover`
                        // natif à une vraie grille plein écran, demandé
                        // explicitement le 2026-09-03 ("ça doit m'ouvrir une
                        // popup comme pour les templates").
                        ZStack {
                            Color.black.opacity(0.45)
                                .ignoresSafeArea()
                                .onTapGesture { appState.shotPickerPageIndex = nil }
                            ShotPickerView(pageIndex: pageIndex, maxHeight: popupMaxHeight)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .onExitCommand { appState.shotPickerPageIndex = nil }
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: appState.showTemplatePicker)
            .animation(.easeOut(duration: 0.15), value: appState.shotPickerPageIndex)
            .animation(.easeOut(duration: 0.15), value: appState.showOnboardingVideo)
            .alert(
                "Erreur",
                isPresented: Binding(
                    get: { appState.lastError != nil },
                    set: { if !$0 { appState.lastError = nil } }
                )
            ) {
                Button("OK") { appState.lastError = nil }
            } message: {
                Text(appState.lastError ?? "")
            }
        }
    }

    /// Écran d'accueil — design fourni par l'utilisateur le 2026-09-02 :
    /// en-tête (titre + actions à droite), "Projets récents" (les 3 plus
    /// récents, en cartes), "Anciens projets" (le reste, en liste) —
    /// portage de rien de précis côté Python (LandingDialog n'a que
    /// Nouveau/Charger, pas de parcours de projets existants) : nouvelle
    /// fonctionnalité côté Swift. Polices Monument Grotesk (32/16/12,
    /// voir Theme.swift:AppFonts).
    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 16) {
                    Text("Bienvenue sur DigitalMockup")
                        .font(.monumentGrotesk(32))
                    Spacer()
                    HStack(spacing: 10) {
                        Button("Nouveau projet") { appState.showTemplatePicker = true }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Charger un projet") { appState.presentOpenBlendPanel() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .font(.monumentGrotesk(12))
                }

                // "Mise en place" — portage de landing_dialog.py, réduit à
                // la SEULE étape encore pertinente côté Swift : le choix
                // du dossier de projets. Pas d'étape "Installer les
                // dépendances" — WebCapture (WKWebView natif) n'en a
                // aucune, contrairement à Playwright/Chromium côté
                // Python. Disparaît une fois choisi, mais ne bloque
                // jamais Nouveau/Charger — juste un rappel.
                if !appState.hasChosenProjectsRoot {
                    HStack(spacing: 10) {
                        Text("Mise en place :").dimText()
                        Button {
                            appState.presentChangeProjectsRootPanel()
                        } label: {
                            Text("Choisir l'emplacement des dossiers")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .font(.monumentGrotesk(12))
                }

                let recent = Array(appState.recentProjects.prefix(3))
                let remainingProjects = Array(appState.recentProjects.dropFirst(3))
                // Bornée (demande explicite du 2026-09-08 : "il faudrait
                // mettre une limite au nombre de projets dans anciens
                // projets") — un dossier de projets qui grossit avec le
                // temps ne doit pas transformer l'écran d'accueil en
                // liste sans fin à faire défiler. Le lien "Voir tout"
                // (à côté du titre) donne accès au reste via le Finder.
                let older = Array(remainingProjects.prefix(Self.olderProjectsLimit))

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Projets récents").font(.monumentGrotesk(16))
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 16
                        ) {
                            ForEach(recent) { summary in
                                RecentProjectCard(summary: summary)
                            }
                        }
                    }
                }

                if !older.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        // "Voir tout" à côté du titre (pas un bouton pleine
                        // largeur sous la liste) — mise en page reprise du
                        // visuel Figma définitif fourni le 2026-09-08.
                        // Ouvre le Finder quoi qu'il arrive (pas seulement
                        // s'il y a du contenu cropté) : raccourci général
                        // "voir tout", pas juste un accès au surplus caché.
                        HStack {
                            Text("Anciens projets").font(.monumentGrotesk(16))
                            Spacer()
                            Button {
                                appState.openProjectsFolderInFinder()
                            } label: {
                                Text("Voir tout")
                            }
                            .buttonStyle(.plain)
                            .dimText()
                            .font(.monumentGrotesk(12))
                        }
                        VStack(spacing: 10) {
                            ForEach(older) { summary in
                                OlderProjectRow(summary: summary)
                            }
                        }
                    }
                }
            }
            // Marge horizontale à 80pt (demande explicite du 2026-09-08,
            // le double des 40pt d'origine) — verticale inchangée à 40.
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
            // Contenu à taille FIXE, PAS étiré en agrandissant la fenêtre
            // (demande explicite du 2026-09-08 : "même quand on agrandit
            // la fenêtre ça agrandit pas le contenu") — le 1er `.frame`
            // plafonne la largeur RÉELLE du contenu (cartes "Projets
            // récents" incluses, elles utilisent des colonnes flexibles
            // qui s'étiraient sinon avec la largeur disponible) ; le 2ème
            // `.frame(maxWidth: .infinity)` étire seulement le CONTENEUR
            // autour de ce contenu plafonné pour le centrer — l'espace en
            // trop sur un grand écran devient une marge vide symétrique,
            // pas du contenu grossi.
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear { appState.refreshRecentProjects() }
    }
}

/// Une carte "Projets récents" — clique pour rouvrir ce projet
/// (AppState.loadProject, même chemin que "Charger un projet").
private struct RecentProjectCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    let summary: ProjectService.ProjectSummary
    @State private var isHovered = false

    var body: some View {
        // `.onTapGesture` plutôt qu'un `Button` : un Button macOS, même
        // stylé `.plain`, peut dessiner un halo natif de survol/
        // interaction qui déborde de la forme personnalisée qu'on lui
        // donne (constaté par l'utilisateur : liseré visible au-dessus de
        // chaque carte, avant même son coin arrondi) — un simple geste de
        // tap n'a aucun chrome système à supprimer.
        VStack(alignment: .leading) {
            Spacer()
            Text(summary.displayName)
                .font(.monumentGrotesk(14))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .bottomLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(isHovered ? palette.surfaceHover : palette.surface))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { appState.loadProject(fromBlendPath: summary.blendPath) }
        .onHover { isHovered = $0 }
    }
}

/// Une ligne "Anciens projets".
private struct OlderProjectRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    let summary: ProjectService.ProjectSummary
    @State private var isHovered = false

    var body: some View {
        // `.onTapGesture` plutôt qu'un `Button` — voir le commentaire de
        // RecentProjectCard.body juste au-dessus (même correctif).
        HStack {
            Text(summary.displayName).font(.monumentGrotesk(14))
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(isHovered ? palette.surfaceHover : palette.surface))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { appState.loadProject(fromBlendPath: summary.blendPath) }
        .onHover { isHovered = $0 }
    }
}

/// Grille de templates presets — portage de
/// template_picker.py:pick_template (CardGridDialog). "Mode libre" est un
/// bouton d'échappement en coin (pas un second écran/un toggle, design
/// revu le 2026-09-02) : lance directement avec le template par défaut,
/// aucune sélection déjà faite pour l'utilisateur — même règle que
/// main_window.py:_default_free_mode_template. Grille 3 colonnes, mêmes
/// proportions de carte que card_grid.py (CARD_SIZE 220×170, THUMB_SIZE
/// 220×124 — fond noir uni en absence de miniature, plus de "?").
struct TemplatePickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette

    /// Calculée (pas `let`) : l'écart entre cartes est réglable en direct
    /// depuis SpacingDebugPanel — voir TemplatePickerSpacing.swift.
    private var columns: [GridItem] {
        [
            GridItem(.fixed(220), spacing: TemplatePickerSpacing.gridSpacing),
            GridItem(.fixed(220), spacing: TemplatePickerSpacing.gridSpacing),
            GridItem(.fixed(220)),
        ]
    }

    /// Extraite du corps de `body` : le compilateur peine à type-checker
    /// cette expression arithmétique quand elle est écrite en ligne dans
    /// un `.frame(...)` au milieu d'une hiérarchie de vues déjà complexe
    /// ("unable to type-check this expression in reasonable time").
    private var popupWidth: CGFloat {
        let cardsWidth = 3 * 220.0
        let gridGaps = 2 * TemplatePickerSpacing.gridSpacing
        let outer = 2 * TemplatePickerSpacing.outerPadding
        return cardsWidth + gridGaps + outer
    }

    /// Plus de `@Environment(\.dismiss)` (spécifique aux vraies `.sheet`
    /// système) — cette vue est maintenant un overlay maison (voir
    /// ContentView.body), fermé en repassant simplement le drapeau à faux.
    private func dismiss() {
        appState.showTemplatePicker = false
    }

    private func startFreeMode() {
        let template = appState.templates.first(where: { $0.id == "tablette" }) ?? appState.templates.first
        if let template {
            appState.createProject(from: template, forceFreeMode: true)
            dismiss()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Choisissez un preset").font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Mode libre") { startFreeMode() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(appState.templates.isEmpty)
            }

            Spacer().frame(height: TemplatePickerSpacing.headerToGridSpacing)

            if appState.templates.isEmpty {
                VStack(spacing: 8) {
                    Text("Aucun template preset n'est encore configuré.")
                    Text("Ajoute des presets dans templates/, ou ouvre un fichier .blend existant depuis l'écran d'accueil.")
                }
                .font(.caption)
                .dimText()
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                // `.fixedSize(vertical: true)` : sans ça, la ScrollView est
                // le seul enfant flexible du VStack et SwiftUI lui donne
                // TOUT l'espace vertical restant jusqu'au plafond du popup
                // (voir plus bas) — même quand le contenu réel (2 rangées
                // de cartes) est bien plus petit. Ce remplissage silencieux
                // s'ajoutait au Spacer du curseur "Grille → séparateur",
                // créant un vide double, sans curseur pour le second.
                // `.fixedSize` fait épouser la hauteur réelle du contenu ;
                // `.frame(maxHeight:)` en dessous garde un vrai défilement
                // si un jour il y a trop de presets pour tenir.
                ScrollView {
                    LazyVGrid(columns: columns, spacing: TemplatePickerSpacing.gridSpacing) {
                        ForEach(appState.templates) { template in
                            TemplateCard(template: template) {
                                appState.createProject(from: template, forceFreeMode: false)
                                dismiss()
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 320)
            }

            Spacer().frame(height: TemplatePickerSpacing.gridToDividerSpacing)
            Divider().overlay(palette.border)
            Spacer().frame(height: TemplatePickerSpacing.dividerToFooterSpacing)

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(TemplatePickerSpacing.outerPadding)
        // Pas de `maxHeight` fixe sur le popup entier : un plafond arbitraire
        // (560, choisi à l'origine pour matcher la taille de lancement de
        // la fenêtre) rognait silencieusement toute augmentation des
        // marges/espacements une fois le contenu proche de cette limite —
        // constaté par l'utilisateur : au-delà d'un certain point, la marge
        // extérieure du popup ne bougeait plus. La grille (ScrollView
        // au-dessus) a déjà SON PROPRE plafond de défilement (320, voir
        // plus haut), donc le popup entier peut suivre son contenu réel
        // sans ceinture supplémentaire — rien n'empêche plus les curseurs
        // du panneau de réglage d'avoir un effet visible.
        .frame(width: popupWidth)
        .modalCardBackground()
    }
}

/// Une carte de la grille de templates — portage de QFrame#card
/// (card_grid.py) : rayon 14, surface, léger éclaircissement au survol,
/// miniature 220×124 (fond noir en absence de miniature — voir
/// HoverVideoThumbnail), nom ET durée sur la MÊME ligne (nom à gauche,
/// durée à droite — design revu le 2026-09-02, plus l'un sous l'autre).
private struct TemplateCard: View {
    @Environment(\.appPalette) private var palette
    let template: Template
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        // `.onTapGesture` plutôt qu'un `Button` (portage macOS d'un souci
        // de chrome natif suspecté — retenu même si ce n'était PAS la
        // vraie cause du liseré, voir plus bas).
        //
        // VRAIE cause trouvée après plusieurs essais (screenshot annoté
        // par l'utilisateur, deux fois) : la hauteur totale FIXE (170)
        // posée sur ce VStack était plus grande que son contenu réel
        // (miniature 124 + ligne de texte, qui totalisent MOINS) —
        // `.frame(height:)` centre verticalement par défaut quand le
        // contenu est plus petit que la taille imposée, ce qui poussait
        // tout le VStack vers le bas et laissait un espace vide en HAUT,
        // au-dessus de la miniature. L'espace équivalent en BAS était
        // invisible (même couleur `palette.surface` que la ligne de texte
        // qui le recouvre), d'où un liseré visible seulement en haut.
        // Fix : plus de hauteur fixe — seule la largeur est imposée, la
        // hauteur suit le contenu réel, aucune place pour du slack.
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            HStack(alignment: .firstTextBaseline) {
                Text(template.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let duration = template.duration {
                    Text(duration).font(.caption).dimText()
                }
            }
            .padding(TemplatePickerSpacing.cardTextPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 220)
        .background(isHovered ? palette.surfaceHover : palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        // `surface` (pas `surfaceHover`) : même couleur que le fond de la
        // carte elle-même (juste en dessous, le bloc titre/durée) — sinon
        // deux gris différents créent une coupure visible entre les deux
        // (constaté par l'utilisateur).
        ZStack {
            palette.surface
            HoverVideoThumbnail(thumbnailPath: template.thumbnailPath, videoPath: template.videoPath)
        }
        .frame(width: 220, height: 124)
    }
}
