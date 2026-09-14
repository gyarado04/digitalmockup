import Foundation

/// Mêmes règles de validation que main_window.py (juste avant de construire
/// `config` et d'appeler render_process.start) — voir chaque cas pour le
/// message affiché côté Python d'origine.
public enum RenderPreparationError: Error, CustomStringConvertible {
    case missingPresetPlans([String])
    case missingCaptures([String])
    case noAssignedPages

    public var description: String {
        switch self {
        case .missingPresetPlans(let names):
            return "Ce preset doit utiliser tous ses plans avant de pouvoir rendre — "
                + "il en manque encore \(names.count), non assignés à aucune page :\n"
                + names.joined(separator: "\n")
        case .missingCaptures(let names):
            return "Captures manquantes pour : \(names.joined(separator: ", "))\n"
                + "Capture ces pages avant de lancer le rendu."
        case .noAssignedPages:
            return "Aucune page n'a de plan assigné — assigne au moins un plan "
                + "(bouton 'Actualiser les plans' puis 'Assigner un plan')."
        }
    }
}

/// Construit le dictionnaire de config attendu par blender_side/headless.py
/// (cmd_render / PageSync) à partir d'un Project — portage direct de la
/// partie validation + construction de `config` dans
/// main_window.py:_launch_render (avant l'appel à render_process.start).
public enum RenderConfigBuilder {
    /// Même nom de fichier que PREVIEW_FILENAME côté main_window.py.
    public static let previewFilename = "_apercu_frame.png"

    public static func buildConfig(for project: Project) throws -> (config: [String: Any], previewPath: String) {
        let baseDir = project.baseDir

        // Preset à plans figés : tous ses plans doivent être assignés à une
        // page ou une autre avant de rendre — sinon certains seraient
        // silencieusement absents de la vidéo finale (le rendu ne fait que
        // sauter les plans non assignés, voir headless.py:_blocks_to_render).
        if project.locked,
           let template = TemplateCatalog.findTemplate(byId: project.templateId),
           let order = template.presetPlanOrder {
            let assigned = Set(project.pages.flatMap { $0.cameras.filter { !$0.isEmpty } })
            let missingPlans = order.filter { !assigned.contains($0) }
            if !missingPlans.isEmpty {
                throw RenderPreparationError.missingPresetPlans(missingPlans)
            }
        }

        var pagesConfig: [[String: Any]] = []
        var missingCaptures: [String] = []
        for page in project.pages {
            let cameras = page.cameras.filter { !$0.isEmpty }
            guard !cameras.isEmpty else { continue }
            guard project.pageHasCaptures(page, baseDir: baseDir) else {
                missingCaptures.append(page.name.isEmpty ? "(sans nom)" : page.name)
                continue
            }
            // "camera_sections" (plan assigné à une section, défilant
            // seulement [scroll_start, scroll_end] de la page à son propre
            // rythme) vivait ici — fonctionnalité "Sections importantes"
            // RETIRÉE le 2026-09-08, demande explicite de l'utilisateur.
            // headless.py retombe désormais TOUJOURS sur le scroll auto à
            // vitesse constante (comportement d'origine, jamais retouché).
            let pageConfig: [String: Any] = [
                "uid": page.uid,
                "name": page.name,
                "cameras": cameras,
                "desktop_path": project.pageDesktopPath(page, baseDir: baseDir),
                "mobile_path": project.pageMobilePath(page, baseDir: baseDir),
            ]
            pagesConfig.append(pageConfig)
        }

        if !missingCaptures.isEmpty {
            throw RenderPreparationError.missingCaptures(missingCaptures)
        }
        if pagesConfig.isEmpty {
            throw RenderPreparationError.noAssignedPages
        }

        let renderDir = project.renderDir(baseDir: baseDir)
        try FileManager.default.createDirectory(atPath: renderDir, withIntermediateDirectories: true)
        let previewPath = (renderDir as NSString).appendingPathComponent(previewFilename)

        var config: [String: Any] = [
            "mode": project.renderMode.rawValue,
            "render_dir": renderDir,
            "output_name": project.outputName(),
            "preview_path": previewPath,
            "pages": pagesConfig,
        ]
        // Dérogations de couleur — seulement si l'utilisateur les a
        // vraiment réglées (nil = garder la couleur d'origine du
        // template), voir headless.py:apply_color_override.
        if project.colorPickerEnabled, let hex = project.backgroundColorHex {
            config["background_color_hex"] = hex
        }
        if project.colorPickerEnabled, let hex = project.deviceColorHex {
            config["device_color_hex"] = hex
        }
        return (config, previewPath)
    }

    /// Config pour `headless.py:cmd_color_preview` — un seul still avec les
    /// couleurs Fond/Tablette (réglages avancés) appliquées, bouton
    /// "Aperçu" à côté des color pickers (2026-09-07). Volontairement
    /// PEU exigeant contrairement à `buildConfig` (rendu final) : pas
    /// besoin que toutes les pages soient capturées, juste que le rendu
    /// démarre — si aucune page n'a de capture ni de plan assigné, on
    /// prévisualise quand même les couleurs sur l'écran tel qu'il était
    /// déjà dans le `.blend` plutôt que de bloquer l'utilisateur avec une
    /// erreur pour un simple aperçu.
    public static func buildColorPreviewConfig(
        for project: Project, backgroundColorHex: String?, deviceColorHex: String?
    ) -> (config: [String: Any], outputPath: String) {
        let baseDir = project.baseDir
        let outputPath = NSTemporaryDirectory() + "agence_color_preview_" + UUID().uuidString + ".png"

        var config: [String: Any] = ["output_path": outputPath]
        if let backgroundColorHex { config["background_color_hex"] = backgroundColorHex }
        if let deviceColorHex { config["device_color_hex"] = deviceColorHex }

        // Meilleure page dispo pour rendre l'aperçu réaliste (vrai contenu
        // à l'écran, pas juste un écran vide) : la première page qui a à
        // la fois un plan assigné ET une vraie capture sur disque — sinon
        // on laisse `camera`/`desktop_path`/`mobile_path` absents,
        // cmd_color_preview s'en accommode.
        if let page = project.pages.first(where: { page in
            !page.cameras.filter({ !$0.isEmpty }).isEmpty && project.pageHasCaptures(page, baseDir: baseDir)
        }), let camera = page.cameras.first(where: { !$0.isEmpty }) {
            config["camera"] = camera
            config["desktop_path"] = project.pageDesktopPath(page, baseDir: baseDir)
            config["mobile_path"] = project.pageMobilePath(page, baseDir: baseDir)
        }

        return (config, outputPath)
    }
}
