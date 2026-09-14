import Foundation

/// Portage de app/core/templates.py — presets livrés avec l'app, décrits
/// par templates/manifest.json (même fichier que côté Python, lu tel quel).
public struct Template: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var blendPath: String
    public var thumbnailPath: String?
    public var duration: String?
    public var videoPath: String?
    /// Non-nil = preset à plans figés (voir Project.locked côté Project.swift
    /// et main_window.py:_start_new_project_from_template côté Python) —
    /// liste ORDONNÉE de tous les noms de caméra du preset.
    public var presetPlanOrder: [String]?

    public init(
        id: String, name: String, blendPath: String, thumbnailPath: String? = nil,
        duration: String? = nil, videoPath: String? = nil, presetPlanOrder: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.blendPath = blendPath
        self.thumbnailPath = thumbnailPath
        self.duration = duration
        self.videoPath = videoPath
        self.presetPlanOrder = presetPlanOrder
    }
}

public enum TemplateCatalog {
    /// templates/ — même repli bundled/dev que
    /// BlenderBridge.headlessScriptPath() (voir son commentaire) : un vrai
    /// .app empaqueté l'embarque dans Contents/Resources/templates/,
    /// cherché EN PREMIER ; sinon on remonte depuis les sources de CE
    /// fichier jusqu'à la racine du projet (mode dev, `swift run`).
    public static func templatesRoot() -> String {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("templates")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent()  // AgenceTemplate3DCore/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // swift-app/
            .deletingLastPathComponent()  // racine du projet
        return projectRoot.appendingPathComponent("templates").path
    }

    /// Lit templates/manifest.json et retourne les Template dont le .blend
    /// déclaré existe réellement — un preset mal configuré est ignoré
    /// plutôt que de faire planter le sélecteur (même règle que
    /// list_templates() côté Python).
    public static func listTemplates() -> [Template] {
        let root = templatesRoot()
        let manifestPath = (root as NSString).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["templates"] as? [[String: Any]] else {
            return []
        }

        var result: [Template] = []
        for entry in entries {
            guard let blend = entry["blend"] as? String else { continue }
            let blendPath = (root as NSString).appendingPathComponent(blend)
            guard FileManager.default.fileExists(atPath: blendPath) else { continue }

            let id = entry["id"] as? String ?? blend
            let name = entry["name"] as? String ?? "Sans nom"
            let thumbnail = (entry["thumbnail"] as? String).map { (root as NSString).appendingPathComponent($0) }
            let video = (entry["video"] as? String).map { (root as NSString).appendingPathComponent($0) }
            let duration = entry["duration"] as? String
            let presetPlans = entry["preset_plans"] as? [String]

            result.append(Template(
                id: id, name: name, blendPath: blendPath, thumbnailPath: thumbnail,
                duration: duration, videoPath: video, presetPlanOrder: presetPlans
            ))
        }
        return result
    }

    public static func findTemplate(byId id: String) -> Template? {
        listTemplates().first(where: { $0.id == id })
    }

    /// Le Template dont le .blend correspond EXACTEMENT à ce chemin, ou nil
    /// — portage de find_template_by_blend_path côté Python : utilisé quand
    /// l'utilisateur ouvre "à la main" un fichier qui se trouve être un
    /// preset original (via "Charger un projet"), pour ne jamais le
    /// modifier directement (voir ProjectService.createProject à la place).
    public static func findTemplate(byBlendPath blendPath: String) -> Template? {
        let target = URL(fileURLWithPath: blendPath).resolvingSymlinksInPath().path
        return listTemplates().first {
            URL(fileURLWithPath: $0.blendPath).resolvingSymlinksInPath().path == target
        }
    }

    /// Vrai si blendPath pointe vers un fichier À L'INTÉRIEUR de templates/
    /// — un preset original, jamais à modifier/écraser directement.
    public static func isPresetPath(_ blendPath: String) -> Bool {
        guard !blendPath.isEmpty else { return false }
        let root = URL(fileURLWithPath: templatesRoot()).standardizedFileURL.path
        let target = URL(fileURLWithPath: blendPath).standardizedFileURL.path
        return target == root || target.hasPrefix(root + "/")
    }

    /// Copie le .blend du template vers l'emplacement du nouveau projet
    /// client — ne touche jamais au fichier source du preset.
    public static func instantiateTemplate(_ template: Template, destination: String) throws {
        let destDir = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        try FileManager.default.copyItem(atPath: template.blendPath, toPath: destination)
    }

    private static let photoExtensions = [".png", ".jpg", ".jpeg"]
    private static let videoFilename = "video.mp4"

    /// Portage de app/core/templates.py:shot_assets_for_camera — photo/vidéo
    /// fournies À LA MAIN pour ce plan (caméra) d'un preset donné, ou
    /// (nil, nil) si rien n'a été déposé. Convention par dossier, pas de
    /// déclaration dans manifest.json — il suffit de déposer les fichiers :
    ///
    ///     templates/<templateId>/shots/<caméra assainie>/photo.png (ou .jpg/.jpeg)
    ///     templates/<templateId>/shots/<caméra assainie>/video.mp4
    ///
    /// Une photo déposée ici prend le pas sur la miniature EEVEE
    /// auto-rendue par `list_shots` (voir AppState.refreshShots) ; la
    /// vidéo, elle, n'existe QUE via ce mécanisme — `list_shots` n'en rend
    /// jamais (voir headless.py:cmd_list_shots).
    public static func shotAssets(templateId: String?, cameraName: String) -> (photo: String?, video: String?) {
        guard let templateId, !templateId.isEmpty else { return (nil, nil) }
        let folder = (templatesRoot() as NSString)
            .appendingPathComponent(templateId)
        let shotFolder = (folder as NSString)
            .appendingPathComponent("shots")
        let cameraFolder = (shotFolder as NSString)
            .appendingPathComponent(sanitizeFolderName(cameraName, fallback: "shot"))

        var photo: String?
        for ext in photoExtensions {
            let candidate = (cameraFolder as NSString).appendingPathComponent("photo" + ext)
            if FileManager.default.fileExists(atPath: candidate) {
                photo = candidate
                break
            }
        }
        let videoCandidate = (cameraFolder as NSString).appendingPathComponent(videoFilename)
        let video = FileManager.default.fileExists(atPath: videoCandidate) ? videoCandidate : nil
        return (photo, video)
    }
}

// ── catégorisation des plans (convention de nom de caméra) ──

public let planCategories = ["Desktop", "Transition", "Mobile"]

/// Catégorie d'un plan (caméra) d'après son nom — convention "<nom> -
/// <Catégorie>" (ex. "Plan 3 - Desktop"). nil si hors convention.
public func planCategory(_ cameraName: String) -> String? {
    guard let range = cameraName.range(of: " - ", options: .backwards) else { return nil }
    let suffix = cameraName[range.upperBound...].trimmingCharacters(in: .whitespaces)
    return planCategories.first(where: { $0.lowercased() == suffix.lowercased() })
}
