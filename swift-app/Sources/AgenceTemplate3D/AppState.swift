import AgenceTemplate3DCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// État de l'app — portage (encore partiel) de MainWindow côté Python.
/// Chaque changement de projet est sauvegardé sur disque (pas de debounce
/// pour l'instant, contrairement à _mark_dirty côté Python — à ajouter si
/// ça devient un problème de perf réelle, pas avant).
@MainActor
@Observable
final class AppState {
    var project: Project?
    var templates: [Template] = []
    var isListingShots = false
    var lastError: String?
    /// Piloté à la fois par le bouton "Nouveau projet" de l'écran d'accueil
    /// et par le menu Fichier — vit ici plutôt que dans un @State de
    /// ContentView pour être atteignable depuis les deux.
    var showTemplatePicker = false
    /// `nil` = fermé ; sinon l'index de la page qui est en train de
    /// choisir un plan ("Assigner un plan", PageRowView) — vit ici plutôt
    /// que dans un @State local à PlanPickerButton pour être affiché en
    /// overlay PLEIN ÉCRAN par ContentView (comme showTemplatePicker),
    /// pas dans un simple `.popover()` ancré au bouton — demandé
    /// explicitement le 2026-09-03 ("ça doit m'ouvrir une popup comme
    /// pour les templates").
    var shotPickerPageIndex: Int?
    /// Projets client trouvés sur disque (`<projectsRoot>/Vidéo
    /// présentation projet/`), du plus récent au plus ancien — pour
    /// l'écran d'accueil ("Projets récents"/"Anciens projets", design
    /// fourni par l'utilisateur le 2026-09-02). Recalculé à l'ouverture de
    /// l'écran d'accueil et après chaque retour dessus (voir
    /// refreshRecentProjects()), pas en continu.
    var recentProjects: [ProjectService.ProjectSummary] = []

    // ── réglages avancés : bouton "Aperçu" des couleurs (voir previewColors) ──
    var isGeneratingColorPreview = false
    var colorPreviewPath: String?
    var colorPreviewError: String?

    // ── capture web (voir capturePage(at:)) ──
    /// uid des pages en cours de capture — plusieurs captures ne peuvent
    /// PAS tourner en parallèle sur le même WKWebView, mais rien n'empêche
    /// de suivre l'état de plusieurs pages ; on sérialise quand même (voir
    /// capturePage) pour rester simple et éviter de saturer le réseau/CPU.
    var capturingPageUIDs: Set<Int> = []
    /// uid des pages dont desktop+mobile existent sur disque — recalculé
    /// après chaque création de projet / capture réussie plutôt qu'à chaque
    /// affichage (évite de taper le disque à chaque redraw SwiftUI).
    var capturedPageUIDs: Set<Int> = []
    /// uid -> fraction 0.0…1.0 de la capture EN COURS pour cette page —
    /// desktop = 1ère moitié [0, 0.5], mobile = 2ème [0.5, 1.0] (2 appels
    /// séquentiels à `WebCapture.captureFrameSequence`, voir
    /// `capturePage`). 2026-09-08, demande explicite : la capture prend
    /// maintenant le temps d'un vrai scroll (~10-60s) — un simple spinner
    /// indéterminé ne suffit plus, il faut voir où ça en est.
    var capturingPageProgress: [Int: Double] = [:]

    // ── renommage auto du dossier/du .blend d'après le nom du site ──
    private var renameWorkItem: DispatchWorkItem?

    // ── rendu (voir startRender()) ──
    private var renderProcess: RenderProcess?
    var isRendering = false
    var renderProgress: RenderProgress?
    /// Dernier message de fin ("Rendu terminé"/"Rendu annulé"/erreur) —
    /// affiché en ligne dans l'UI, pas une alerte (même choix que
    /// _on_render_finished côté Python : pas de QMessageBox systématique).
    var renderStatusMessage: String?
    var previewImagePath: String?
    /// Incrémenté à chaque AGENCE_PREVIEW reçu — l'aperçu est réécrit AU
    /// MÊME chemin à chaque frame, donc rien d'autre ne signale à SwiftUI
    /// qu'il faut relire le fichier.
    var previewRefreshToken = 0

    private let defaults = UserDefaults.standard
    private static let projectsRootKey = "projects_root"

    var projectsRoot: String {
        get { defaults.string(forKey: Self.projectsRootKey) ?? ProjectService.defaultProjectsRoot() }
        set {
            defaults.set(newValue, forKey: Self.projectsRootKey)
            hasChosenProjectsRoot = true
        }
    }

    /// Vrai seulement si l'utilisateur a EXPLICITEMENT choisi un dossier —
    /// pas juste "une valeur existe" (`projectsRoot` retombe toujours sur
    /// un défaut silencieux). Portage de `root_ok` dans
    /// landing_dialog.py:_refresh_setup_state — pilote l'étape "Mise en
    /// place" de l'écran d'accueil (voir ContentView.landing).
    ///
    /// PROPRIÉTÉ STOCKÉE, pas calculée à partir d'UserDefaults à chaque
    /// lecture — @Observable ne suit que les propriétés stockées ; une
    /// calculée qui lit une source externe (UserDefaults) ne notifie
    /// jamais SwiftUI d'un changement, même si `projectsRoot` change
    /// juste à côté (bug constaté : le bouton "Choisir l'emplacement des
    /// dossiers" ne disparaissait jamais après un choix réel).
    private(set) var hasChosenProjectsRoot: Bool

    // ── vidéo de présentation (voir OnboardingVideoSheet.swift) ──
    /// Montrée à l'ouverture de l'app (une fois, sauf "Ne plus afficher")
    /// ET rejouable à la demande depuis Paramètres — demande explicite du
    /// 2026-09-08. PROPRIÉTÉ STOCKÉE (même raison que
    /// `hasChosenProjectsRoot` juste au-dessus).
    var showOnboardingVideo = false
    private static let hasSeenOnboardingVideoKey = "has_seen_onboarding_video"

    /// Case à cocher "Ne plus afficher à l'ouverture" — PROPRIÉTÉ STOCKÉE,
    /// `didSet` persiste dans `UserDefaults` (même pattern que
    /// `projectsRoot`/`hasChosenProjectsRoot` juste au-dessus). Bug
    /// corrigé le 2026-09-08 ("le bouton ne se cochait pas quand je
    /// cliquais dessus") : d'abord écrite comme propriété CALCULÉE
    /// lisant `UserDefaults` directement — exactement le piège déjà
    /// documenté sur `hasChosenProjectsRoot` ("`@Observable` ne suit que
    /// les propriétés stockées ; une calculée qui lit une source externe
    /// ne notifie JAMAIS SwiftUI d'un changement") — la valeur changeait
    /// bien dans UserDefaults, mais SwiftUI ne redessinait jamais la case
    /// pour le montrer.
    var suppressOnboardingVideoOnLaunch: Bool {
        didSet { defaults.set(suppressOnboardingVideoOnLaunch, forKey: Self.hasSeenOnboardingVideoKey) }
    }

    init() {
        hasChosenProjectsRoot = UserDefaults.standard.string(forKey: Self.projectsRootKey) != nil
        templates = TemplateCatalog.listTemplates()
        recentProjects = []
        suppressOnboardingVideoOnLaunch = UserDefaults.standard.bool(forKey: Self.hasSeenOnboardingVideoKey)
        refreshRecentProjects()
        showOnboardingVideo = !suppressOnboardingVideoOnLaunch
    }

    /// Ferme la vidéo de présentation (croix, clic hors du popup, ou
    /// Échap — même 3 façons que `TemplatePickerView`/`ShotPickerView`).
    /// NE mémorise RIEN à elle seule : c'est la case à cocher "Ne plus
    /// afficher à l'ouverture" (`suppressOnboardingVideoOnLaunch` juste en
    /// dessous) qui décide si elle réapparaît au prochain lancement — les
    /// deux sont indépendantes (design fourni par l'utilisateur le
    /// 2026-09-08 : une case à cocher à part, pas un bouton qui ferme ET
    /// mémorise en même temps).
    func closeOnboardingVideo() {
        showOnboardingVideo = false
    }

    /// Rouvre la vidéo de présentation à la demande ("Voir la vidéo de
    /// présentation", Paramètres) — indépendant du drapeau "déjà vue" :
    /// un utilisateur qui a cliqué "Ne plus afficher" doit pouvoir quand
    /// même la revoir explicitement.
    func presentOnboardingVideo() {
        showOnboardingVideo = true
    }

    /// Portage du scan de projets pour l'écran d'accueil — recalculé à
    /// l'ouverture (ContentView.landing:.onAppear) plutôt qu'en continu,
    /// une lecture disque à chaque redraw serait du gâchis.
    ///
    /// Ne scanne PAS tant que l'utilisateur n'a jamais choisi de dossier
    /// explicitement (voir `hasChosenProjectsRoot`) : `projectsRoot`
    /// retombe silencieusement sur un chemin par défaut sous
    /// `~/Documents/...`, et lire ce dossier "à l'aveugle" avant même que
    /// l'utilisateur ait fait quoi que ce soit fait apparaître le popup
    /// système "« DigitalMockup » souhaite accéder aux fichiers de votre
    /// dossier Documents" AU LANCEMENT, avant même que la fenêtre soit
    /// visible — signalé explicitement par l'utilisateur le 2026-09-03.
    /// Une fois le dossier choisi via `presentChangeProjectsRootPanel()`
    /// (NSOpenPanel, geste utilisateur explicite — pas soumis à cette
    /// protection), le scan reprend normalement.
    func refreshRecentProjects() {
        guard hasChosenProjectsRoot else {
            recentProjects = []
            return
        }
        recentProjects = ProjectService.listRecentProjects(projectsRoot: projectsRoot)
    }

    /// Ouvre `<projectsRoot>/Vidéo présentation projet/` dans le Finder —
    /// demande explicite du 2026-09-08 : "Anciens projets" est maintenant
    /// borné (voir `ContentView.olderProjectsLimit`) pour ne pas afficher
    /// une liste sans fin ; ce bouton donne accès à tout le reste (même
    /// dossier que celui scanné par `listRecentProjects`).
    func openProjectsFolderInFinder() {
        let folder = (projectsRoot as NSString).appendingPathComponent(ProjectService.presentationSubfolder)
        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
    }

    /// "Charger un projet" — portage de main_window.py:_choose_blend. Si le
    /// fichier choisi est un preset original (dans templates/), on en crée
    /// une copie de travail plutôt que de charger l'original tel quel
    /// (jamais y toucher directement, même règle que la création depuis un
    /// template) ; sinon on charge/relit le .agence_project.json à côté.
    func loadProject(fromBlendPath blendPath: String) {
        if let template = TemplateCatalog.findTemplate(byBlendPath: blendPath) {
            createProject(from: template, forceFreeMode: false)
            return
        }
        project = ProjectStore.loadOrCreate(forBlendPath: blendPath)
        capturingPageUIDs = []
        capturingPageProgress = [:]
        isRendering = false
        renderProgress = nil
        renderStatusMessage = nil
        refreshCapturedPages()
        refreshShots()
    }

    /// Portage de template_picker.py:pick_existing_file + _choose_blend —
    /// NSOpenPanel (pas de macro SwiftUI, juste AppKit) plutôt qu'un
    /// composant SwiftUI, pour rester utilisable aussi bien depuis un
    /// bouton que depuis le menu Fichier.
    func presentOpenBlendPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choisir un fichier .blend"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let blendType = UTType(filenameExtension: "blend") {
            panel.allowedContentTypes = [blendType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(fromBlendPath: url.path)
    }

    /// "Télécharger la vidéo" (bouton dans `OnboardingVideoView`) — copie
    /// le fichier vidéo bundlé (`onboarding_video.mp4`, voir son
    /// commentaire ⚠️ PLACEHOLDER) vers un emplacement choisi par
    /// l'utilisateur. `NSSavePanel` direct (même style que
    /// `presentOpenBlendPanel`/`presentChangeProjectsRootPanel` juste en
    /// dessous : AppKit, `.runModal()` synchrone, pas de composant
    /// SwiftUI), demande explicite du 2026-09-08.
    func downloadOnboardingVideo() {
        guard let sourceURL = Bundle.module.url(forResource: "onboarding_video", withExtension: "mp4") else {
            lastError = "Vidéo de présentation introuvable."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Enregistrer la vidéo de présentation"
        panel.nameFieldStringValue = "DigitalMockup - Présentation.mp4"
        if let mp4Type = UTType(filenameExtension: "mp4") {
            panel.allowedContentTypes = [mp4Type]
        }
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            lastError = "Impossible d'enregistrer la vidéo : \(error.localizedDescription)"
        }
    }

    /// Portage de main_window.py:_change_projects_root.
    func presentChangeProjectsRootPanel() {
        let panel = NSOpenPanel()
        panel.title = "Dossier des projets clients"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: projectsRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectsRoot = url.path
        refreshRecentProjects()
    }

    func createProject(from template: Template, forceFreeMode: Bool) {
        do {
            let created = try ProjectService.createProject(
                from: template, projectsRoot: projectsRoot, forceFreeMode: forceFreeMode
            )
            project = created
            capturingPageUIDs = []
            capturingPageProgress = [:]
            refreshCapturedPages()
            refreshShots()
        } catch {
            lastError = "Impossible de créer le projet : \(error)"
        }
    }

    func save() {
        guard let project else { return }
        do {
            try ProjectStore.save(project)
        } catch {
            lastError = "Impossible d'enregistrer le projet : \(error)"
        }
    }

    /// Change le nom du site + programme le renommage auto du dossier/du
    /// .blend 1200ms après la dernière frappe — portage de
    /// main_window.py:_on_site_changed (+ _rename_timer).
    func siteNameChanged(_ newValue: String) {
        project?.siteName = newValue
        save()
        scheduleRenameToSiteName()
    }

    private func scheduleRenameToSiteName() {
        renameWorkItem?.cancel()
        renameWorkItem = nil
        guard let project, !project.siteName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let workItem = DispatchWorkItem { [weak self] in self?.flushPendingRename() }
        renameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    /// Exécute le renommage tout de suite (annule le debounce en attente
    /// s'il y en avait un) — portage de _rename_project_to_site_name
    /// (partie disque en Core, voir ProjectService.renameProjectToSiteName)
    /// + du déclenchement immédiat que fait closeEvent côté Python quand
    /// l'utilisateur quitte pendant que le timer de 1200ms tourne encore
    /// (ici : quand on quitte le projet via "Menu", voir closeProject()).
    func flushPendingRename() {
        renameWorkItem?.cancel()
        renameWorkItem = nil
        guard let project else { return }
        // "Trop risqué de déplacer des fichiers en cours d'usage" — même
        // garde-fou que côté Python.
        guard !isRendering, capturingPageUIDs.isEmpty else { return }

        switch ProjectService.renameProjectToSiteName(project) {
        case .unchanged:
            break
        case .renamed(let updated):
            self.project = updated
            refreshCapturedPages()
        case .renamedWithWarning(let updated, let message):
            self.project = updated
            lastError = message
            refreshCapturedPages()
        case .blocked(let message), .failed(let message):
            lastError = message
        }
    }

    /// "Menu" — ferme le projet courant, mais flushe d'abord un
    /// renommage en attente (sinon le nom de client tapé juste avant de
    /// cliquer "Menu" serait perdu côté fichiers, même si déjà enregistré
    /// dans le JSON) — équivalent de closeEvent côté Python.
    func closeProject() {
        flushPendingRename()
        project = nil
        refreshRecentProjects()
    }

    func addPage() {
        project?.addPage()
        save()
    }

    func removePage(at index: Int) {
        _ = project?.removePage(at: index)
        save()
    }

    /// Lit les caméras du .blend (list_shots) — appel Blender potentiellement
    /// long (rendu EEVEE d'une miniature par caméra), hors du thread
    /// principal (Task.detached), l'UI reste réactive pendant ce temps.
    func refreshShots() {
        guard let project else { return }
        let blendPath = project.blendPath
        let templateId = project.templateId
        let cacheDir = NSTemporaryDirectory() + "agence_shots_cache_" + UUID().uuidString
        isListingShots = true

        Task {
            let outcome: Result<(shots: [CameraShot], fps: Double?), Error> = await Task.detached {
                do {
                    let result = try BlenderBridge.runHeadless(
                        blendPath: blendPath, command: "list_shots", config: ["cache_dir": cacheDir]
                    )
                    let shotsRaw = result["shots"] as? [[String: Any]] ?? []
                    let shots: [CameraShot] = shotsRaw.compactMap { dict in
                        guard let name = dict["name"] as? String else { return nil }
                        // Une photo/vidéo déposée à la main pour ce plan
                        // (voir TemplateCatalog.shotAssets) prend le pas
                        // sur la miniature EEVEE auto-rendue par
                        // list_shots — un plan est visuellement identique
                        // d'un projet client à l'autre pour un même
                        // preset, autant montrer le bel aperçu fourni
                        // plutôt que le rendu basse résolution automatique.
                        // La vidéo, elle, n'existe QUE via ce mécanisme —
                        // list_shots n'en rend jamais. Portage de
                        // main_window.py:_apply_shot_assets.
                        let assets = TemplateCatalog.shotAssets(templateId: templateId, cameraName: name)
                        return CameraShot(
                            name: name, thumbnail: assets.photo ?? (dict["thumbnail"] as? String),
                            video: assets.video, frames: dict["frames"] as? Int
                        )
                    }
                    return .success((shots, result["fps"] as? Double))
                } catch {
                    return .failure(error)
                }
            }.value

            isListingShots = false
            // Garde-fou "réponse en retard" : si l'utilisateur a fermé ce
            // projet ou en a ouvert un autre PENDANT l'appel Blender
            // (async, peut prendre plusieurs secondes), `self.project` a
            // changé entre-temps — appliquer quand même ce résultat (succès
            // OU erreur) écraserait les plans du NOUVEAU projet actif, ou
            // pire, afficherait une erreur concernant un vieux projet par-
            // dessus l'écran d'un autre, totalement déroutant. Signalé
            // explicitement par l'utilisateur le 2026-09-03 : une erreur
            // "Preset 1 (5)" (un vieux projet de test) affichée alors que
            // "ETI AURA 3" était l'écran actif.
            guard self.project?.blendPath == blendPath else { return }
            switch outcome {
            case .success(let (shots, fps)):
                self.project?.camerasCache = shots
                if let fps { self.project?.fps = fps }
                self.save()
            case .failure(let error):
                self.lastError = "Lecture des caméras impossible : \(error)"
            }
        }
    }

    /// Recalcule quelles pages ont déjà leurs 2 captures (desktop+mobile)
    /// sur disque — portage de _refresh_pages_state côté Python (partie
    /// "état des captures", pas la partie plans/miniatures).
    func refreshCapturedPages() {
        guard let project else {
            capturedPageUIDs = []
            return
        }
        let baseDir = project.baseDir
        capturedPageUIDs = Set(
            project.pages
                .filter { project.pageHasCaptures($0, baseDir: baseDir) }
                .map(\.uid)
        )
    }

    /// Capture desktop (1920×1080) puis mobile (390×844) pour cette page —
    /// portage de main_window.py:_capture_page (capture_desktop_and_mobile
    /// côté Python, WebCapture natif ici). Une capture à la fois par page ;
    /// WKWebView doit tourner sur le thread principal donc pas de
    /// Task.detached ici, mais l'app reste réactive : chaque `await` cède
    /// la main entre les étapes (chargement, scroll, snapshot).
    ///
    /// `captureFrameSequence` (PAS `capture`) depuis le 2026-09-08 :
    /// enregistre le scroll en temps réel (séquence d'images numérotées,
    /// voir son commentaire) plutôt qu'une seule image pleine page — sinon
    /// les animations d'apparition au scroll (fade-in, slide-in…) ne
    /// montrent jamais leur MOUVEMENT dans le rendu final, seulement leur
    /// état terminé. Nettement plus lent (le temps d'un vrai scroll,
    /// ~10-60s selon la page, contre quelques secondes avant) et plus
    /// lourd sur disque (des dizaines de PNG par page) — décision
    /// explicite de l'utilisateur de remplacer la capture par défaut
    /// PARTOUT plutôt qu'un réglage optionnel.
    func capturePage(at index: Int) {
        guard let project, project.pages.indices.contains(index) else { return }
        let page = project.pages[index]
        guard !page.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = "Renseigne l'URL du site à capturer pour cette page"
            return
        }
        guard let url = URL(string: page.url), url.scheme != nil else {
            lastError = "URL invalide pour '\(page.name)' : \(page.url)"
            return
        }
        guard !capturingPageUIDs.contains(page.uid) else { return }

        let baseDir = project.baseDir
        let pageDir = project.pageDir(page, baseDir: baseDir)
        let desktopPath = project.pageDesktopPath(page, baseDir: baseDir)
        let mobilePath = project.pageMobilePath(page, baseDir: baseDir)
        let uid = page.uid
        let blendPath = project.blendPath

        capturingPageUIDs.insert(uid)
        capturingPageProgress[uid] = 0

        Task {
            defer {
                capturingPageUIDs.remove(uid)
                capturingPageProgress.removeValue(forKey: uid)
            }
            do {
                try FileManager.default.createDirectory(atPath: pageDir, withIntermediateDirectories: true)
                // Deux WKWebView séparées (une par capture) : repartir d'un
                // chargement propre pour chaque viewport, comme le
                // page.goto() répété côté Python (scroll à 0, animations
                // "once" pas déjà déclenchées).
                //
                // `onProgress` : `WebCapture` est `@MainActor`, ce
                // callback est donc déjà appelé sur le MainActor — pas
                // besoin de `Task { @MainActor in ... }` comme pour
                // `RenderProcess.onProgress` (qui vient d'un process
                // externe, hors MainActor). Desktop = 1ère moitié [0,0.5]
                // de la barre, mobile = 2ème [0.5,1.0].
                try await WebCapture().captureFrameSequence(
                    url: url, viewportWidth: 1920, viewportHeight: 1080, outputDir: desktopPath,
                    onProgress: { fraction in
                        guard self.project?.blendPath == blendPath else { return }
                        self.capturingPageProgress[uid] = fraction * 0.5
                    }
                )
                try await WebCapture().captureFrameSequence(
                    url: url, viewportWidth: 390, viewportHeight: 844, outputDir: mobilePath,
                    onProgress: { fraction in
                        guard self.project?.blendPath == blendPath else { return }
                        self.capturingPageProgress[uid] = 0.5 + fraction * 0.5
                    }
                )
                // Garde-fou "réponse en retard" (même piège que
                // refreshShots, voir son commentaire) : si l'utilisateur a
                // changé de projet PENDANT cette capture (peut prendre
                // plusieurs secondes), ne pas rafraîchir l'état captures/
                // afficher une erreur pour un projet qui n'est plus actif.
                guard self.project?.blendPath == blendPath else { return }
                refreshCapturedPages()
            } catch {
                guard self.project?.blendPath == blendPath else { return }
                lastError = "Échec de la capture de '\(page.name)' : \(error)"
            }
        }
    }

    // ── réglages du projet : couleurs (2026-09-07) ──
    // Propres à CE projet (pas des préférences globales de l'app) — vivent
    // directement dans la colonne de gauche, pas dans une fenêtre
    // "Paramètres" séparée, demande explicite du 2026-09-07.
    // ("Sections importantes" vivait ici aussi, retiré le 2026-09-08 à la
    // demande de l'utilisateur — voir mémoire projet pour l'historique
    // complet de cette fonctionnalité, abandonnée après plusieurs pivots.)

    func setColorPickerEnabled(_ enabled: Bool) {
        guard project?.colorPickerEnabled != enabled else { return }
        project?.colorPickerEnabled = enabled
        save()
    }

    func setBackgroundColorHex(_ hex: String?) {
        project?.backgroundColorHex = hex
        save()
    }

    func setDeviceColorHex(_ hex: String?) {
        project?.deviceColorHex = hex
        save()
    }

    /// Bouton "Aperçu" à côté des color pickers (AdvancedSettingsSheet) —
    /// un vrai rendu Blender (1 still, réglages TEST) avec les couleurs
    /// Fond/Tablette ACTUELLEMENT choisies, même si elles n'ont pas encore
    /// été sauvegardées comme réglage définitif du projet (previewBg/
    /// previewDevice passés explicitement plutôt que lus sur
    /// `project.backgroundColorHex` : l'utilisateur doit pouvoir prévisu-
    /// aliser une couleur avant de la valider). Chemin de sortie unique à
    /// chaque appel (UUID, voir RenderConfigBuilder) — jamais réutiliser un
    /// chemin fixe ici, sinon un appel qui échoue silencieusement laisse
    /// croire à tort que l'aperçu a été mis à jour (piège déjà rencontré
    /// cette session avec un ancien harnais de test, voir la mémoire du
    /// projet).
    func previewColors(background: String?, device: String?) {
        guard let project, !isGeneratingColorPreview else { return }
        let blendPath = project.blendPath
        isGeneratingColorPreview = true
        colorPreviewError = nil

        Task {
            // `config`/`outputPath` construits DEDANS la tâche détachée
            // (pas capturés depuis l'extérieur) : `[String: Any]` n'est pas
            // `Sendable`, seuls `project` (struct Sendable) et les 2
            // `String?` le sont — sinon Swift 6 refuse de compiler
            // (concurrence stricte, "risks causing data races").
            let outcome: Result<String, Error> = await Task.detached {
                let (config, outputPath) = RenderConfigBuilder.buildColorPreviewConfig(
                    for: project, backgroundColorHex: background, deviceColorHex: device
                )
                do {
                    try BlenderBridge.runHeadless(blendPath: blendPath, command: "color_preview", config: config)
                    return .success(outputPath)
                } catch {
                    return .failure(error)
                }
            }.value

            isGeneratingColorPreview = false
            // Garde-fou "réponse en retard" — même piège que refreshShots/
            // capturePage/startRender (voir leurs commentaires) : si le
            // projet a changé pendant l'appel Blender, cet aperçu ne
            // concerne plus le bon projet.
            guard self.project?.blendPath == blendPath else { return }
            switch outcome {
            case .success(let path):
                colorPreviewPath = path
            case .failure(let error):
                colorPreviewError = "Aperçu impossible : \(error)"
            }
        }
    }

    // ── rendu ──

    func setRenderMode(_ mode: RenderMode) {
        guard project?.renderMode != mode else { return }
        project?.renderMode = mode
        save()
    }

    /// Portage de main_window.py:_launch_production — mêmes validations
    /// (RenderConfigBuilder), puis démarre RenderProcess (Core) en streaming.
    func startRender() {
        guard let project else { return }
        guard !isRendering else {
            lastError = "Un rendu est déjà en cours"
            return
        }
        do {
            let (config, previewPath) = try RenderConfigBuilder.buildConfig(for: project)
            previewImagePath = previewPath
            renderProgress = nil
            renderStatusMessage = nil
            isRendering = true

            let process = RenderProcess()
            renderProcess = process

            process.onProgress = { [weak self] progress in
                Task { @MainActor in
                    self?.renderProgress = progress
                }
            }
            process.onPreviewUpdated = { [weak self] _ in
                Task { @MainActor in
                    self?.previewRefreshToken += 1
                }
            }
            let blendPath = project.blendPath
            process.onFinished = { [weak self] ok, message in
                Task { @MainActor in
                    guard let self else { return }
                    // `isRendering`/`renderProcess` sont des drapeaux
                    // GLOBAUX (pas par projet) — toujours les réinitialiser
                    // pour ne jamais laisser "Lancer le rendu" bloqué
                    // désactivé sur le projet ACTUEL si l'utilisateur a
                    // changé de projet pendant ce rendu.
                    self.isRendering = false
                    self.renderProcess = nil
                    // Garde-fou "réponse en retard" (même piège que
                    // refreshShots/capturePage, voir leurs commentaires),
                    // pour la partie vraiment spécifique à CE projet : son
                    // message de fin ne doit pas s'afficher sur l'écran
                    // d'un projet qui n'est plus le bon.
                    guard self.project?.blendPath == blendPath else { return }
                    self.renderStatusMessage = message
                    self.refreshCapturedPages()  // le rendu ne change pas les captures, mais coûte rien à revérifier
                }
            }

            try process.start(blendPath: project.blendPath, config: config)
        } catch let error as RenderPreparationError {
            isRendering = false
            lastError = error.description
        } catch {
            isRendering = false
            lastError = "Impossible de lancer le rendu : \(error)"
        }
    }

    /// Annulation SYNCHRONE côté RenderProcess (voir son commentaire) —
    /// appelée depuis un bouton, donc bloque l'UI quelques secondes le
    /// temps de confirmer que Blender est mort ; acceptable, même choix
    /// que côté Python (RenderProcess.cancel y est documentée pareil).
    func cancelRender() {
        renderProcess?.cancel()
    }
}
