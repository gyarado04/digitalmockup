import AgenceTemplate3DCore
import AppKit
import SwiftUI

/// Portage de la disposition à 2 colonnes de main_window.py : à gauche
/// site/pages/plans + mode Test/Final + Lancer le rendu, à droite
/// PreviewPanel (aperçu du rendu, TOUJOURS visible, pas seulement pendant
/// un rendu — voir preview_panel.py). Style : Theme.swift (couleurs de
/// app/ui/theme.py).
struct ProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    private var columns = ProjectViewSpacing.shared
    /// Page "Paramètres" (bouton engrenage, en-tête colonne de gauche) —
    /// voir ProjectSettingsSheet.swift : n'y vit QUE l'interrupteur
    /// d'activation (Couleurs personnalisées), pas son contenu — demande
    /// explicite du 2026-09-07 : "l'utilisation se fait dans le projet
    /// mais l'activation se fait dans la page paramètres".
    @State private var showingProjectSettings = false

    /// La colonne de gauche garde toujours au moins cette largeur, même en
    /// glissant la poignée à fond — voir le commentaire sur
    /// `ProjectViewSpacing.rightColumnWidthRange`.
    private static let minLeftColumnWidth: CGFloat = 320
    private static let horizontalPadding: CGFloat = 40  // 20 de chaque côté, voir .padding(.horizontal, 20) plus bas

    /// Largeur MAX que peut prendre la colonne aperçu à cet instant, compte
    /// tenu de la largeur réelle de la fenêtre — dynamique (pas une
    /// constante), recalculée à chaque redimensionnement de fenêtre.
    private func maxRightColumnWidth(availableWidth: CGFloat) -> Double {
        max(
            ProjectViewSpacing.rightColumnWidthRange.lowerBound,
            Double(availableWidth - Self.horizontalPadding - ProjectViewSpacing.columnSpacing - Self.minLeftColumnWidth)
        )
    }

    var body: some View {
        @Bindable var appState = appState
        // `GeometryReader` + `.frame(minHeight: geo.size.height)` sur le
        // contenu : sans ça, la ScrollView remplit bien toute la fenêtre
        // (elle est "responsive"), mais son CONTENU (le HStack des 2
        // colonnes) ne fait que sa hauteur naturelle et reste collé en
        // haut — une ScrollView n'étire JAMAIS un contenu plus petit
        // qu'elle pour remplir sa hauteur, elle ne fait que permettre le
        // défilement s'il est plus grand. Signalé explicitement par
        // l'utilisateur le 2026-09-03 ("c'est pas responsive en hauteur")
        // avec une fenêtre étirée bien plus haute que le contenu, laissant
        // tout le bas en noir vide. `minHeight` force le contenu à occuper
        // AU MOINS toute la fenêtre (les cartes s'étirent, voir
        // RenderPreviewPanel/leftColumn plus bas) tout en gardant le
        // défilement normal si le contenu dépasse (beaucoup de pages).
        GeometryReader { geo in
            let maxRightWidth = maxRightColumnWidth(availableWidth: geo.size.width)
            ScrollView {
                // `spacing: 0` : la poignée de redimensionnement occupe
                // elle-même l'espace entre les 2 colonnes (via sa propre
                // largeur, réglée sur columnSpacing) — pas de gap fixe
                // séparé sinon la poignée serait décalée du vrai bord de
                // la colonne aperçu.
                HStack(alignment: .top, spacing: 0) {
                    leftColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    ColumnResizeHandle(maxRightColumnWidth: maxRightWidth)
                    // Pas de maxHeight ici : la carte "Aperçu du rendu"
                    // garde sa hauteur naturelle (comme avant), seule la
                    // colonne de gauche s'étire — demandé explicitement le
                    // 2026-09-03. `min(...)` : si la fenêtre est
                    // rétrécie après coup (pas seulement via la poignée),
                    // la largeur mémorisée ne doit pas non plus écraser la
                    // colonne de gauche.
                    RenderPreviewPanel()
                        .frame(width: min(columns.rightColumnWidth, maxRightWidth))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                // Marge du haut plus généreuse : barre de titre masquée
                // (.windowStyle(.hiddenTitleBar), App.swift) — les ronds
                // rouge/jaune/vert flottent au-dessus, ce contenu ne doit
                // pas passer dessous.
                .padding(.top, 36)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showingProjectSettings) {
            ProjectSettingsSheet()
        }
    }

    /// Portait aussi un `SectionEditorPanel` optionnel à droite des pages
    /// (quand `appState.sectionEditorTarget` était réglé) — toute la
    /// fonctionnalité "Sections importantes" retirée le 2026-09-08 (demande
    /// explicite), `leftColumn` n'est plus qu'un simple alias de
    /// `pagesColumn` désormais.
    private var leftColumn: some View { pagesColumn }

    @ViewBuilder
    private var pagesColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(appState.project?.templateName ?? "Projet").font(.system(size: 17, weight: .bold))
                Spacer()
                Button {
                    showingProjectSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Paramètres du projet")
                Button("Menu") { appState.closeProject() }.buttonStyle(SecondaryButtonStyle())
            }

            if let project = appState.project {
                HStack(spacing: 8) {
                    Text("Site :").dimText()
                    TextField(
                        "Nom du client",
                        text: Binding(
                            get: { project.siteName },
                            set: { newValue in appState.siteNameChanged(newValue) }
                        )
                    )
                    .underlineFieldStyle()
                }

                // Contenu des réglages du projet — l'ACTIVATION (les 2
                // toggles) vit dans la page "Paramètres" (bouton engrenage,
                // en-tête), mais l'UTILISATION reste ici dans le projet
                // (demande explicite du 2026-09-07 : "l'utilisation se fait
                // dans le projet mais l'activation se fait dans la page
                // paramètres"). Toujours piloté par le flag
                // `Project.colorPickerEnabled`.
                if project.colorPickerEnabled {
                    ProjectColorSettingsView()
                }

                if appState.isListingShots {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Lecture des plans du .blend…").dimText()
                    }
                }

                VStack(spacing: 10) {
                    ForEach(Array(project.pages.enumerated()), id: \.element.id) { index, _ in
                        PageRowView(pageIndex: index)
                            .padding(14)
                            .panelBackground(cornerRadius: 14, dashed: true)
                    }
                }

                if !project.locked {
                    Button {
                        appState.addPage()
                    } label: {
                        Text("Ajouter une page").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                // Consomme l'espace laissé par `.frame(maxHeight: .infinity)`
                // côté appelant (ProjectView.body) — pousse "Ajouter une
                // page" plaqué en HAUT de la colonne quand la fenêtre est
                // plus haute que le contenu, au lieu de laisser l'espace en
                // trop tout en bas — demandé explicitement le 2026-09-03.
                // Le sélecteur Test/Rendu final + Lancer le rendu ont migré
                // dans la colonne de droite, sous le cadre d'aperçu (voir
                // RenderPreviewPanel) — demande explicite du 2026-09-07.
                Spacer(minLength: 0)
            }
        }
    }
}

/// Poignée de redimensionnement entre les 2 colonnes de ProjectView —
/// glisser horizontalement change en direct `ProjectViewSpacing.shared
/// .rightColumnWidth`. Demandé explicitement par l'utilisateur le
/// 2026-09-03 à la place d'un curseur de panneau de debug ("je veux pas
/// des valeurs en dure, je veux pouvoir glisser pour ajuster la taille de
/// la colonne").
///
/// Zone de saisie (largeur = `ProjectViewSpacing.columnSpacing`) plus
/// large que le trait visible (1-2pt) : plus facile à attraper à la
/// souris sans viser un trait d'un pixel — même idiome que les
/// séparateurs de colonnes d'Xcode/Finder. Cette largeur EST l'espace
/// visuel entre les 2 colonnes (pas de spacing séparé sur le HStack
/// parent, voir ProjectView.body).
private struct ColumnResizeHandle: View {
    @Environment(\.appPalette) private var palette
    private var columns = ProjectViewSpacing.shared
    /// Limite haute dynamique (largeur de fenêtre actuelle moins la place
    /// minimum à laisser à la colonne de gauche) — passée par ProjectView,
    /// recalculée à chaque redimensionnement de fenêtre. Remplace l'ancien
    /// plafond FIXE (560) qui faisait "bloquer" le glissement bien avant
    /// le bord de la fenêtre sur un grand écran.
    let maxRightColumnWidth: Double
    @State private var isHovering = false
    /// Largeur de la colonne aperçu au moment où le glissement a commencé
    /// — le glissement raisonne en delta depuis CE point de départ, pas
    /// en position absolue de la souris, sinon la colonne "saute" au
    /// premier mouvement.
    @State private var widthAtDragStart: Double?

    var body: some View {
        ZStack {
            // Pas de changement de COULEUR au survol (demandé explicitement
            // le 2026-09-03) — juste un trait légèrement plus épais, dans
            // la même teinte neutre que le reste des séparateurs de l'app.
            Rectangle()
                .fill(palette.border)
                .frame(width: isHovering ? 2 : 1)
        }
        .frame(width: ProjectViewSpacing.columnSpacing)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let startWidth = widthAtDragStart ?? columns.rightColumnWidth
                    if widthAtDragStart == nil { widthAtDragStart = startWidth }
                    // La colonne aperçu est ancrée au bord droit : glisser
                    // la poignée vers la GAUCHE (translation négative) doit
                    // AGRANDIR cette colonne, glisser vers la droite la
                    // rétrécit — d'où le signe inversé.
                    columns.setRightColumnWidth(startWidth - drag.translation.width, maxAllowed: maxRightColumnWidth)
                }
                .onEnded { _ in widthAtDragStart = nil }
        )
        .help("Glisser pour ajuster la largeur de la colonne aperçu")
    }
}

/// Portage de la partie "Mode + production" de main_window.py (les
/// boutons Test/Rendu final + Lancer/Annuler le rendu). Vit désormais DANS
/// RenderPreviewPanel (colonne de droite), sous le cadre d'aperçu — migré
/// depuis la colonne de gauche le 2026-09-07, demande explicite.
struct RenderControlsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                modeButton(.test, label: "Test")
                modeButton(.final, label: "Rendu")
            }

            // Temps de CALCUL attendu (combien de temps l'ordinateur va y
            // passer) — demande explicite du 2026-09-07, prévenir avant de
            // lancer. PAS la même chose que `estimatedDurationText`
            // juste en dessous, qui est la durée de la VIDÉO produite
            // (nombre de frames ÷ fps) — les deux sont utiles mais ne
            // répondent pas à la même question, d'où 2 lignes distinctes.
            Text(renderTimeExpectationText).font(.caption).dimText()

            if let estimatedDurationText {
                Text(estimatedDurationText).font(.caption).dimText()
            }

            // Un seul bouton qui bascule Lancer/Annuler selon l'état du
            // rendu (demande explicite du 2026-09-07 : plus un bouton
            // "Annuler le rendu" séparé ailleurs). Deux `Button` CONCRETS
            // distincts dans un if/else plutôt qu'un seul bouton avec un
            // style choisi par ternaire — un `ButtonStyle` choisi par
            // ternaire entre deux styles concrets différents pouvait rester
            // bloqué sur les couleurs de l'ancien thème après une bascule
            // clair/sombre (bug déjà rencontré le 2026-09-03, voir
            // modeButton juste en dessous) ; l'if/else crée deux identités
            // de vue séparées, donc pas de risque de ce genre ici.
            if appState.isRendering {
                Button {
                    appState.cancelRender()
                } label: {
                    Text("Annuler le rendu").frame(maxWidth: .infinity)
                }
                .buttonStyle(DestructiveButtonStyle())
                .controlSize(.large)
            } else {
                // Bleu (accent) dans les DEUX thèmes — demandé
                // explicitement le 2026-09-03, pour que ce soit clairement
                // LE bouton d'action principal de la page (l'accent n'est
                // plus utilisé pour indiquer le mode sélectionné juste
                // au-dessus, voir modeButton — les deux se feraient
                // concurrence visuellement sinon).
                Button {
                    appState.startRender()
                } label: {
                    Text("Lancer le rendu").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.large)
            }
        }
    }

    /// PAS l'accent bleu pour indiquer le mode sélectionné (réservé à
    /// "Lancer le rendu" — demande explicite du 2026-09-03) : un seul et
    /// même `SecondaryButtonStyle` pour les deux boutons (au lieu de
    /// basculer entre Primary/Secondary), la sélection se voit via une
    /// bordure accent + une coche, superposées PAR-DESSUS ce style commun.
    /// Évite au passage le bug de rendu constaté juste avant ce changement
    /// (un `AnyButtonStyle` choisi par ternaire entre deux styles
    /// CONCRETS différents pouvait rester bloqué sur les couleurs de
    /// l'ancien thème après une bascule clair/sombre) — plus qu'un seul
    /// style concret ici, plus de risque de ce genre.
    @ViewBuilder
    private func modeButton(_ mode: RenderMode, label: String) -> some View {
        let isSelected = (appState.project?.renderMode ?? .test) == mode
        Button {
            appState.setRenderMode(mode)
        } label: {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? palette.accent : Color.clear, lineWidth: 1)
        )
        .disabled(appState.isRendering)
    }

    /// Portage de main_window.py:_update_duration_estimate — somme du
    /// nombre de frames de CHAQUE plan assigné (project.cameras_cache),
    /// pas juste le plus long segment : deux plans utilisés s'additionnent
    /// dans la vidéo finale (l'un après l'autre).
    /// Ordre de grandeur générique (pas un calcul par projet, contrairement
    /// à `estimatedDurationText`) — EEVEE (Test) vs Cycles haute qualité
    /// (Rendu final) ont des temps de calcul par frame très différents,
    /// l'utilisateur doit le savoir AVANT de cliquer "Lancer le rendu".
    private var renderTimeExpectationText: String {
        switch appState.project?.renderMode ?? .test {
        case .test:
            return "Temps de rendu (Test) : quelques minutes en moyenne"
        case .final:
            return "Temps de rendu (Rendu) : quelques heures en moyenne"
        }
    }

    private var estimatedDurationText: String? {
        guard let project = appState.project else { return nil }
        let framesByCamera = Dictionary(
            uniqueKeysWithValues: project.camerasCache.compactMap { shot -> (String, Int)? in
                guard let frames = shot.frames else { return nil }
                return (shot.name, frames)
            }
        )
        var totalFrames = 0
        var anyAssigned = false
        var anyUnknown = false
        for page in project.pages {
            for name in page.cameras where !name.isEmpty {
                anyAssigned = true
                if let frames = framesByCamera[name] {
                    totalFrames += frames
                } else {
                    anyUnknown = true
                }
            }
        }
        guard anyAssigned else { return nil }
        // "de la vidéo" — précision explicite du 2026-09-07 pour ne pas la
        // confondre avec `renderTimeExpectationText` juste au-dessus
        // (temps de CALCUL, pas la durée du fichier produit).
        if anyUnknown { return "Durée estimée de la vidéo : calcul en cours…" }
        let fps = project.fps > 0 ? project.fps : 24.0
        return "Durée estimée de la vidéo : \(formatEstimatedDuration(Double(totalFrames) / fps))"
    }

    /// "16s" en dessous d'une minute, "1min 30s" au-delà — même format que
    /// _format_duration côté Python.
    private func formatEstimatedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return minutes > 0 ? String(format: "%dmin %02ds", minutes, secs) : "\(secs)s"
    }
}

/// Colonne de droite — portage direct de preview_panel.py:PreviewPanel :
/// titre, aperçu 16:9 en letterbox (toujours visible, même à l'état vide),
/// frame/ETA sur une ligne, barre de progression, message d'état, annuler,
/// ouvrir dans le Finder. Pas encore le bouton bascule sombre/clair
/// (`ToggleSwitch`) — voir Theme.swift : ici on suit l'apparence système au
/// lieu d'un bouton dédié, différence assumée avec Python.
struct RenderPreviewPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    private var themePreference = ThemePreference.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Aperçu du rendu").font(.system(size: 17, weight: .bold))
                Spacer()
                // Portage de preview_panel.py:ToggleSwitch — même
                // emplacement (à droite de "Aperçu du rendu"), même icône
                // qui suit l'état. `Toggle` natif macOS plutôt que redessiné
                // à la main : Python le dessinait lui-même (QSS ne sachant
                // pas produire un vrai interrupteur à glissière), contrainte
                // qui ne s'applique pas ici — SwiftUI en a un tout fait.
                Image(systemName: themePreference.isLight ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textDim)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { themePreference.isLight },
                        set: { themePreference.setLight($0) }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(palette.accent)
                .help("Mode clair / sombre")
            }

            previewBox

            // Sélecteur Test/Rendu final + bouton d'action — sous le cadre
            // d'aperçu, dans la colonne de droite (migré depuis la colonne
            // de gauche le 2026-09-07, demande explicite).
            RenderControlsView()

            if appState.isRendering, let progress = appState.renderProgress {
                infoRow(progress)
                ProgressView(value: fraction(progress))
                    .tint(palette.accent)
            } else if appState.isRendering {
                Text("Démarrage de Blender…").font(.caption).dimText()
            }

            if let message = appState.renderStatusMessage, !appState.isRendering {
                Text(message).font(.caption).dimText()
            }

            // Portage de open_folder_button ("Ouvrir le rendu dans le
            // Finder") — visible une fois un rendu terminé AVEC succès,
            // même règle que finish(ok, message) côté Python.
            if appState.renderStatusMessage == "Rendu terminé" && !appState.isRendering {
                Button {
                    guard let project = appState.project else { return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: project.renderDir(baseDir: project.baseDir)))
                } label: {
                    Text("Ouvrir le rendu dans le Finder").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .panelBackground()
    }

    @ViewBuilder
    private var previewBox: some View {
        ZStack {
            // `palette.surface`/`palette.textDim` (pas des gris fixes codés
            // en dur, comme côté Python) : suit désormais le thème
            // clair/sombre — demandé explicitement le 2026-09-03 ("le
            // cadre du rendu... doit passer en thème clair aussi").
            RoundedRectangle(cornerRadius: 14).fill(palette.surface)
            if let path = appState.previewImagePath, appState.previewRefreshToken > 0,
               let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Text(appState.isRendering ? "En attente de la première frame…" : "Le rendu s'affichera ici,\nframe par frame.")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .foregroundStyle(palette.textDim)
                    .padding()
            }
        }
        // Toujours 16:9 en letterbox, jamais déformé — PREVIEW_RATIO côté Python.
        .aspectRatio(1920.0 / 1080.0, contentMode: .fit)
    }

    @ViewBuilder
    private func infoRow(_ progress: RenderProgress) -> some View {
        HStack {
            Text(String(format: "Frame : %03d/%03d", progress.frame, progress.frameEnd))
            Spacer()
            Text("Temps restant estimé : \(formatETA(progress.etaSeconds))")
                .dimText()
        }
        .font(.caption)
    }

    private func fraction(_ progress: RenderProgress) -> Double {
        let total = max(1, progress.frameEnd - progress.frameStart + 1)
        let done = max(0, min(progress.frame - progress.frameStart + 1, total))
        return Double(done) / Double(total)
    }

    /// Portage exact de _format_eta côté preview_panel.py.
    private func formatETA(_ seconds: Double) -> String {
        guard seconds >= 0 else { return "calcul en cours…" }
        let total = Int(seconds)
        if total < 60 { return "moins d'une minute" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return String(format: "%dh %02dmin", hours, remMinutes)
    }
}

/// Une page — nom, URL, capture, plans assignés. Même ordre que
/// page_widget.py:PageWidget.__init__ : nom+supprimer, URL, capture,
/// "Plans :", cartes, "Assigner un plan".
struct PageRowView: View {
    @Environment(AppState.self) private var appState
    let pageIndex: Int

    private var page: Page? {
        guard let project = appState.project, project.pages.indices.contains(pageIndex) else { return nil }
        return project.pages[pageIndex]
    }

    var body: some View {
        if let page, let project = appState.project {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(
                        "Nom de la page",
                        text: Binding(
                            get: { page.name },
                            set: { newValue in
                                appState.project?.pages[pageIndex].name = newValue
                                appState.save()
                            }
                        )
                    )
                    .underlineFieldStyle()

                    if !project.locked && project.pages.count > 1 {
                        Button(role: .destructive) { appState.removePage(at: pageIndex) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.8))
                    }
                }

                TextField(
                    "https://…",
                    text: Binding(
                        get: { page.url },
                        set: { newValue in
                            appState.project?.pages[pageIndex].url = newValue
                            appState.save()
                        }
                    )
                )
                .underlineFieldStyle()

                captureButton(for: page)

                Text("Plans :").font(.caption).dimText()
                if page.cameras.isEmpty {
                    Text("Aucun plan assigné").font(.caption).dimText()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(page.cameras, id: \.self) { cameraName in
                                PlanChipView(pageIndex: pageIndex, cameraName: cameraName)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                PlanPickerButton(pageIndex: pageIndex)
            }
        }
    }

    /// Portage minimal de _capture_page/_refresh_pages_state côté Python :
    /// bouton → "en cours" (spinner) → "✓ capturé" une fois desktop+mobile
    /// écrits sur disque (WebCapture, Core, voir AppState.capturePage).
    @ViewBuilder
    private func captureButton(for page: Page) -> some View {
        if appState.capturingPageUIDs.contains(page.uid) {
            // Barre DÉTERMINÉE (valeur connue), pas un spinner indéterminé
            // — la capture prend maintenant le temps d'un vrai scroll de
            // la page (~10-60s, voir AppState.capturePage/
            // WebCapture.captureFrameSequence, 2026-09-08), il faut
            // pouvoir voir où ça en est plutôt qu'attendre à l'aveugle.
            let fraction = appState.capturingPageProgress[page.uid] ?? 0
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Capture en cours…").font(.caption).dimText()
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption).monospacedDigit().dimText()
                }
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
        } else {
            Button {
                appState.capturePage(at: pageIndex)
            } label: {
                HStack {
                    if appState.capturedPageUIDs.contains(page.uid) {
                        Label("Recapturer", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("Capturer la page")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// Un plan assigné à une page, en carte — portage direct de PlanCard
/// (page_widget.py) : miniature 150×88 en haut, barre nom + retrait en
/// bas. Distingue "en cours de chargement" (list_shots pas encore
/// terminé) de "introuvable" (plan retiré/renommé côté .blend) — même
/// distinction que page_widget.py:_rebuild_plan_cards (jamais confondre
/// les deux, un triangle d'avertissement pendant un simple chargement
/// induit en erreur).
struct PlanChipView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    let pageIndex: Int
    let cameraName: String

    private static let thumbSize = CGSize(width: 150, height: 88)

    private var shot: CameraShot? {
        appState.project?.camerasCache.first(where: { $0.name == cameraName })
    }
    /// Aucune donnée reçue DU TOUT du .blend pour l'instant.
    private var isLoading: Bool {
        (appState.project?.camerasCache.isEmpty ?? true) && shot == nil
    }
    /// Des données ont été reçues, mais ce plan précis n'y figure pas.
    private var isMissing: Bool { !isLoading && shot == nil }

    var body: some View {
        VStack(spacing: 0) {
            thumbnail
            HStack {
                Text(cameraName)
                    .font(.system(size: 11))
                    .foregroundStyle(isMissing ? palette.warning : palette.text)
                    .lineLimit(1)
                    .help(isMissing ? "Introuvable dans le .blend — retiré ou renommé ?" : cameraName)
                Spacer(minLength: 4)
                Button(action: remove) {
                    Text("–")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textDim)
                .help("Retirer ce plan de la page")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: Self.thumbSize.width)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = shot?.thumbnail, let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .clipped()
        } else {
            // `surface` (pas `surfaceHover`) : même couleur que le fond
            // de la carte (juste en dessous, nom + bouton "–") — sinon
            // coupure visible entre les deux (même bug que TemplateCard,
            // constaté par l'utilisateur).
            Rectangle()
                .fill(palette.surface)
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .overlay {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.warning)
                    } else {
                        Image(systemName: "photo").foregroundStyle(palette.textDim)
                    }
                }
        }
    }

    private func remove() {
        guard var project = appState.project, project.pages.indices.contains(pageIndex) else { return }
        project.pages[pageIndex].cameras.removeAll { $0 == cameraName }
        appState.project = project
        appState.save()
    }
}

/// "Assigner un plan" — ouvre ShotPickerView en overlay plein écran (voir
/// ContentView.body + AppState.shotPickerPageIndex), plus un simple
/// `.popover` ancré au bouton. Reste possible même sur un preset verrouillé
/// (pas de structure figée dans le nombre/l'assignation, seulement dans
/// l'ordre, voir ShotPickerView.assign) — demande utilisateur du
/// 2026-09-01 : "il peut retirer des plans de la première page et en
/// mettre sur la deuxième".
struct PlanPickerButton: View {
    @Environment(AppState.self) private var appState
    let pageIndex: Int

    var body: some View {
        Button {
            appState.shotPickerPageIndex = pageIndex
        } label: {
            // Spinner directement sur le bouton pendant que list_shots
            // tourne encore — demandé explicitement le 2026-09-03, en
            // plus (pas à la place) de l'état de chargement déjà affiché
            // À L'INTÉRIEUR du popup une fois ouvert (voir ShotPickerView) :
            // visible avant même d'avoir cliqué, pas seulement une fois le
            // popup ouvert.
            HStack(spacing: 6) {
                if appState.isListingShots {
                    ProgressView().controlSize(.small)
                }
                Text("Assigner un plan")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(appState.isListingShots)
    }
}

/// Grille de sélection d'un plan à assigner à une page — portage de
/// page_widget.py:_open_shot_picker + card_grid.py (CardGridDialog),
/// trié par catégorie (Desktop/Transition/Mobile/Autres, voir
/// PlanCategory), avec aperçu vidéo au survol via `HoverVideoThumbnail` —
/// le même composant que TemplatePickerView, MAIS `list_shots`
/// (headless.py) ne fournit jamais de vidéo pour un plan, seulement une
/// miniature statique (voir le commentaire de HoverVideoThumbnail) : le
/// survol montrera donc juste la photo statique tant que cette vidéo
/// n'est pas générée côté Blender — le composant est déjà prêt à en
/// profiter le jour où elle existe, rien à changer ici à ce moment-là.
/// Overlay maison plein écran (voir ContentView.body) plutôt qu'un
/// `.popover` natif ancré au bouton — demandé explicitement le
/// 2026-09-03 ("ça doit m'ouvrir une popup comme pour les templates").
struct ShotPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appPalette) private var palette
    let pageIndex: Int
    /// Hauteur MAX de la fenêtre à cet instant moins une marge (voir
    /// ContentView.body) — garde le popup ENTIER dans les limites de la
    /// fenêtre : contrairement à TemplatePickerView (toujours 5 presets,
    /// tient sans plafond), ce popup peut avoir beaucoup de plans répartis
    /// sur 3 catégories, et débordait de la fenêtre par le haut sans ça —
    /// signalé explicitement par l'utilisateur le 2026-09-03.
    let maxHeight: CGFloat

    /// Place à laisser à tout ce qui n'est PAS la grille (titre, espaces,
    /// séparateur, pied de page, marges) pour que le popup entier ne
    /// dépasse jamais `maxHeight` — seule la grille (ScrollView, voir
    /// `gridMaxHeight`) doit rétrécir/défiler, jamais le titre ou le
    /// bouton Annuler qui doivent rester TOUJOURS visibles en entier.
    private static let chromeHeight: CGFloat = 24 + 20 + 20 + 1 + 16 + 32 + 48

    private var gridMaxHeight: CGFloat {
        max(120, maxHeight - Self.chromeHeight)
    }

    private var project: Project? { appState.project }

    private var takenElsewhere: Set<String> {
        guard let project else { return [] }
        var taken = Set<String>()
        for (index, page) in project.pages.enumerated() where index != pageIndex {
            taken.formUnion(page.cameras)
        }
        return taken
    }

    /// Plans déjà assignés à CETTE page — un plan re-choisi ici se
    /// dupliquerait dans page.cameras (assign() fait un append sans
    /// vérifier), donc à exclure autant que ceux pris par une autre page.
    /// Même règle que page_widget.py:_open_shot_picker (qui les grise avec
    /// "Déjà assigné à cette page" plutôt que de les cacher — simplifié ici
    /// en les cachant, cohérent avec le traitement des plans pris ailleurs).
    private var assignedToThisPage: Set<String> {
        guard let project, project.pages.indices.contains(pageIndex) else { return [] }
        return Set(project.pages[pageIndex].cameras)
    }

    private var availableShots: [CameraShot] {
        guard let project else { return [] }
        return project.camerasCache.filter { !takenElsewhere.contains($0.name) && !assignedToThisPage.contains($0.name) }
    }

    /// PlanCategory.grouped travaille sur des NOMS (Core, pas de dépendance
    /// UI) — on ré-associe chaque nom à son CameraShot complet (miniature
    /// incluse) une fois le tri/groupement fait.
    private var groupedShots: [(String?, [CameraShot])] {
        let byName = Dictionary(uniqueKeysWithValues: availableShots.map { ($0.name, $0) })
        return PlanCategory.grouped(availableShots.map(\.name)).map { category, names in
            (category, names.compactMap { byName[$0] })
        }
    }

    private func dismiss() {
        appState.shotPickerPageIndex = nil
    }

    private func assign(_ cameraName: String) {
        guard var project = appState.project, project.pages.indices.contains(pageIndex) else { return }
        project.pages[pageIndex].cameras.append(cameraName)
        if project.locked, let template = TemplateCatalog.findTemplate(byId: project.templateId),
           let order = template.presetPlanOrder {
            project.pages[pageIndex].cameras.sort { a, b in
                (order.firstIndex(of: a) ?? order.count) < (order.firstIndex(of: b) ?? order.count)
            }
        }
        appState.project = project
        appState.save()
        dismiss()
    }

    private var columns: [GridItem] {
        [GridItem(.fixed(220), spacing: 16), GridItem(.fixed(220), spacing: 16), GridItem(.fixed(220))]
    }

    private var popupWidth: CGFloat {
        let cardsWidth = 3 * 220.0
        let gridGaps = 2 * 16.0
        let outer = 2 * 24.0
        return cardsWidth + gridGaps + outer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Assigner un plan").font(.system(size: 17, weight: .bold))
            Spacer().frame(height: 20)

            if appState.isListingShots {
                // Sans cet état, un plan ouvert PENDANT que list_shots
                // tourne encore (ou avant son tout premier passage) montre
                // le même message que "vraiment aucun plan" — signalé
                // explicitement par l'utilisateur le 2026-09-03 : "il
                // faudrait quelque chose qui montre que les plans se
                // chargent et qu'ils sont pas encore visibles".
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Lecture des plans du .blend…").font(.caption).dimText()
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if availableShots.isEmpty {
                Text("Aucun plan disponible.\nSoit tous les plans sont déjà assignés, soit le fichier .blend n'a aucune caméra.")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .dimText()
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                // PAS de `.fixedSize` ici (contrairement à TemplatePickerView) :
                // `.fixedSize(vertical: true)` force la ScrollView à
                // demander sa taille IDÉALE (tout le contenu) en ignorant
                // toute proposition venue d'un `.frame(maxHeight:)` en
                // aval — ça annule le plafond au lieu de juste éviter le
                // remplissage à vide. Constaté le 2026-09-03 : le popup
                // débordait TOUJOURS de la fenêtre malgré `gridMaxHeight`.
                // Un simple `.frame(maxHeight:)` (sans fixedSize) + `.clipped()`
                // garantit un vrai plafond avec défilement — seul
                // inconvénient accepté : avec peu de plans, la grille peut
                // laisser un peu de vide en dessous avant le séparateur,
                // largement préférable à un popup qui déborde de l'écran.
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(groupedShots, id: \.0) { category, shots in
                            VStack(alignment: .leading, spacing: 12) {
                                if let category {
                                    Text(category).font(.system(size: 13, weight: .semibold)).dimText()
                                }
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(shots, id: \.name) { shot in
                                        ShotCard(shot: shot) { assign(shot.name) }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: gridMaxHeight)
                .clipped()
            }

            Spacer().frame(height: 20)
            Divider().overlay(palette.border)
            Spacer().frame(height: 16)

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: popupWidth)
        // Deuxième filet de sécurité sur le popup ENTIER (en plus du
        // plafond posé sur la grille via `gridMaxHeight`) : si jamais
        // `chromeHeight` sous-estime la vraie place prise par le titre/le
        // pied de page, ce `.frame(maxHeight:).clipped()` garantit quand
        // même que le popup ne déborde JAMAIS de la fenêtre.
        .frame(maxHeight: maxHeight)
        .clipped()
        .modalCardBackground()
    }
}

/// Une carte de la grille "Assigner un plan" — même style que TemplateCard
/// (TemplatePickerView, ContentView.swift) : rayon 14, miniature 220×124,
/// nom en dessous.
private struct ShotCard: View {
    @Environment(\.appPalette) private var palette
    let shot: CameraShot
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            Text(shot.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(12)
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
        // carte elle-même — sinon deux gris différents créent une coupure
        // visible entre les deux (même piège déjà rencontré sur
        // TemplateCard).
        ZStack {
            palette.surface
            HoverVideoThumbnail(thumbnailPath: shot.thumbnail, videoPath: shot.video)
        }
        .frame(width: 220, height: 124)
    }
}
