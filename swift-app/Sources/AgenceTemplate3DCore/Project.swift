import Foundation

/// Portage direct de app/core/project.py — mêmes noms de clé JSON
/// (snake_case, via CodingKeys explicites) pour que les fichiers
/// `.agence_project.json` écrits par l'app Python restent lisibles ici et
/// vice versa pendant la transition. Voir project.py pour les commentaires
/// d'origine sur CHAQUE champ ; pas dupliqués ici sauf différence notable.

/// Portait auparavant `ImportantSection` (sections tracées sur une page +
/// assignation d'un plan pour les défiler à un rythme choisi) — toute la
/// fonctionnalité "Sections importantes" RETIRÉE le 2026-09-08, demande
/// explicite de l'utilisateur ("retirer toute la fonctionnalité"), avec
/// tout ce qui allait avec côté app (`ScrollControlView.swift`/
/// `SectionEditorPanel.swift`, `AppState.assignCameraToSection`/etc.) et
/// côté rendu (`camera_sections` dans `RenderConfig.swift`,
/// `camera_own_segment`/`camera_section_fraction` dans `headless.py`).
/// Voir mémoire projet pour l'historique complet (plusieurs pivots de
/// design le 2026-09-07 avant cet abandon).

public struct Page: Codable, Identifiable, Equatable, Sendable {
    public var uid: Int
    public var name: String
    public var url: String
    public var cameras: [String]

    public var id: Int { uid }

    enum CodingKeys: String, CodingKey {
        case uid, name, url, cameras
    }

    public init(uid: Int = 0, name: String = "", url: String = "", cameras: [String] = []) {
        self.uid = uid
        self.name = name
        self.url = url
        self.cameras = cameras
    }

    /// Décodeur explicite (pas l'auto-synthétisé) : `decodeIfPresent` +
    /// défaut sur chaque champ — un vieux/futur `.agence_project.json`
    /// avec des clés en plus ou en moins ne doit jamais faire échouer TOUT
    /// le décodage de `Project.pages`, même règle que Project.init(from:)
    /// plus bas. Les clés `important_sections_desktop/mobile` d'un projet
    /// créé pendant que cette fonctionnalité existait sont silencieusement
    /// ignorées ici (pas dans `CodingKeys`) — comportement standard de
    /// `Decoder`, aucun code de migration nécessaire.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(Int.self, forKey: .uid) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        cameras = try c.decodeIfPresent([String].self, forKey: .cameras) ?? []
    }
}

public struct CameraShot: Codable, Equatable, Sendable {
    public var name: String
    public var thumbnail: String?
    public var video: String?
    /// Nombre de frames du segment de marqueur de ce plan (voir
    /// _camera_segment_frames côté headless.py) — nil si pas encore connu.
    public var frames: Int?

    public init(name: String, thumbnail: String? = nil, video: String? = nil, frames: Int? = nil) {
        self.name = name
        self.thumbnail = thumbnail
        self.video = video
        self.frames = frames
    }

    /// Rétro-compat : les projets créés avant l'ajout des miniatures
    /// stockaient cameras_cache comme une liste de simples noms (String) —
    /// même règle que Project.load_for_blend côté Python.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.name = name
            self.thumbnail = nil
            self.video = nil
            self.frames = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        video = try container.decodeIfPresent(String.self, forKey: .video)
        frames = try container.decodeIfPresent(Int.self, forKey: .frames)
    }
}

public enum RenderMode: String, Codable, Sendable {
    case test = "TEST"
    case final = "FINAL"
}

public struct Project: Codable, Equatable, Sendable {
    public var blendPath: String
    public var siteName: String
    public var templateName: String
    public var templateId: String
    public var pages: [Page]
    public var nextPageUid: Int
    public var renderMode: RenderMode
    public var camerasCache: [CameraShot]
    public var fps: Double
    public var locked: Bool
    /// Révèle les color pickers Fond/Tablette dans la colonne de gauche —
    /// réglage PROPRE À CE PROJET (pas un réglage global de l'app, voir
    /// leftColumn) ; `false` par défaut, ne change rien pour un projet
    /// existant tant que l'utilisateur ne l'active pas.
    public var colorPickerEnabled: Bool
    /// `nil` = pas de dérogation, le template garde sa couleur d'origine
    /// (matériau "Fond" / "Body Apple" côté headless.py). Stocké en hex
    /// `#RRGGBB` (sRGB, converti en linéaire seulement côté headless.py au
    /// moment de l'appliquer au Principled BSDF).
    public var backgroundColorHex: String?
    public var deviceColorHex: String?

    enum CodingKeys: String, CodingKey {
        case blendPath = "blend_path"
        case siteName = "site_name"
        case templateName = "template_name"
        case templateId = "template_id"
        case pages
        case nextPageUid = "next_page_uid"
        case renderMode = "render_mode"
        case camerasCache = "cameras_cache"
        case fps
        case locked
        case colorPickerEnabled = "color_picker_enabled"
        case backgroundColorHex = "background_color_hex"
        case deviceColorHex = "device_color_hex"
    }

    public init(
        blendPath: String = "",
        siteName: String = "",
        templateName: String = "",
        templateId: String = "",
        pages: [Page] = [],
        nextPageUid: Int = 1,
        renderMode: RenderMode = .test,
        camerasCache: [CameraShot] = [],
        fps: Double = 24.0,
        locked: Bool = false,
        colorPickerEnabled: Bool = false,
        backgroundColorHex: String? = nil,
        deviceColorHex: String? = nil
    ) {
        self.blendPath = blendPath
        self.siteName = siteName
        self.templateName = templateName
        self.templateId = templateId
        self.pages = pages
        self.nextPageUid = nextPageUid
        self.renderMode = renderMode
        self.camerasCache = camerasCache
        self.fps = fps
        self.locked = locked
        self.colorPickerEnabled = colorPickerEnabled
        self.backgroundColorHex = backgroundColorHex
        self.deviceColorHex = deviceColorHex
        // Project.__post_init__ côté Python : jamais 0 page.
        if self.pages.isEmpty {
            _ = addPage()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blendPath = try c.decodeIfPresent(String.self, forKey: .blendPath) ?? ""
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        templateName = try c.decodeIfPresent(String.self, forKey: .templateName) ?? ""
        templateId = try c.decodeIfPresent(String.self, forKey: .templateId) ?? ""
        pages = try c.decodeIfPresent([Page].self, forKey: .pages) ?? []
        nextPageUid = try c.decodeIfPresent(Int.self, forKey: .nextPageUid) ?? 1
        renderMode = try c.decodeIfPresent(RenderMode.self, forKey: .renderMode) ?? .test
        camerasCache = try c.decodeIfPresent([CameraShot].self, forKey: .camerasCache) ?? []
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 24.0
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        colorPickerEnabled = try c.decodeIfPresent(Bool.self, forKey: .colorPickerEnabled) ?? false
        backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        deviceColorHex = try c.decodeIfPresent(String.self, forKey: .deviceColorHex)
        if pages.isEmpty {
            let page = Page(uid: nextPageUid, name: "Page 1")
            nextPageUid += 1
            pages.append(page)
        }
    }

    // ── cycle de vie (Project.add_page / remove_page) ──

    @discardableResult
    public mutating func addPage() -> Page {
        let page = Page(uid: nextPageUid, name: "Page \(pages.count + 1)")
        nextPageUid += 1
        pages.append(page)
        return page
    }

    /// Refuse de descendre sous une page — même règle que l'addon/l'app Python.
    @discardableResult
    public mutating func removePage(at index: Int) -> Bool {
        guard pages.count > 1, pages.indices.contains(index) else { return false }
        pages.remove(at: index)
        return true
    }

    /// Dossier du projet — même règle que Project.base_dir côté Python
    /// (dirname du .blend). Les .blend de projet vivent directement dans le
    /// dossier projet (ex. "Preset 1/Preset 1.blend"), jamais dans un
    /// sous-dossier.
    public var baseDir: String {
        (blendPath as NSString).deletingLastPathComponent
    }

    /// `pageDesktopPath`/`pageMobilePath` sont des DOSSIERS de séquence
    /// (voir leur commentaire) — une capture valide doit contenir au moins
    /// `frame_0001.png`, pas juste exister comme dossier vide (ex. laissé
    /// par une capture interrompue).
    public func pageHasCaptures(_ page: Page, baseDir: String) -> Bool {
        Self.hasFirstFrame(at: pageDesktopPath(page, baseDir: baseDir))
            && Self.hasFirstFrame(at: pageMobilePath(page, baseDir: baseDir))
    }

    private static func hasFirstFrame(at sequenceDir: String) -> Bool {
        FileManager.default.fileExists(atPath: (sequenceDir as NSString).appendingPathComponent("frame_0001.png"))
    }

    public func pageFolderName(_ page: Page) -> String {
        sanitizeFolderName(page.name, fallback: "page")
    }

    public func pageDir(_ page: Page, baseDir: String) -> String {
        (sourcesDir(baseDir: baseDir) as NSString).appendingPathComponent(pageFolderName(page))
    }

    /// DOSSIER de séquence d'images (`frame_0001.png`, `frame_0002.png`, …)
    /// — PAS un fichier `.png` unique (2026-09-08, remplace la capture
    /// image fixe pleine page par une capture animée en temps réel qui
    /// préserve le MOUVEMENT des animations d'apparition au scroll, voir
    /// `WebCapture.captureFrameSequence` — une image fixe, même
    /// correctement capturée, ne peut montrer qu'un état final, jamais un
    /// mouvement). Décision explicite de l'utilisateur : remplacer la
    /// capture par défaut PARTOUT plutôt qu'un réglage optionnel par
    /// projet — les anciennes captures `.png` existantes ne sont plus
    /// reconnues (`pageHasCaptures` cherche `frame_0001.png` DANS ce
    /// dossier), il faut recapturer les projets déjà en cours.
    /// `headless.py:sync_texture_node` détecte lui-même qu'il s'agit d'une
    /// séquence (dossier) plutôt que d'une image fixe (fichier) via
    /// `os.path.isdir` — aucun changement de schéma JSON nécessaire.
    public func pageDesktopPath(_ page: Page, baseDir: String) -> String {
        (pageDir(page, baseDir: baseDir) as NSString)
            .appendingPathComponent("web_desktop_\(pageFolderName(page))")
    }

    public func pageMobilePath(_ page: Page, baseDir: String) -> String {
        (pageDir(page, baseDir: baseDir) as NSString)
            .appendingPathComponent("web_mobile_\(pageFolderName(page))")
    }

    /// Chemin de la première frame d'une séquence (`pageDesktopPath`/
    /// `pageMobilePath`) — utilisé pour une MINIATURE représentative (pas
    /// besoin de toute la séquence pour un aperçu statique dans l'UI, voir
    /// `SectionEditorPanel`).
    public static func firstFramePath(inSequenceDir sequenceDir: String) -> String {
        (sequenceDir as NSString).appendingPathComponent("frame_0001.png")
    }

    public func sourcesDir(baseDir: String) -> String {
        (baseDir as NSString).appendingPathComponent("01_CAPTURES")
    }

    public func renderDir(baseDir: String) -> String {
        (baseDir as NSString).appendingPathComponent("02_RENDUS")
    }

    /// "<nom-du-blend>_<site>_<Test|Rendu>_" — Blender ajoute l'extension.
    public func outputName() -> String {
        let blendName = (blendPath as NSString).lastPathComponent
        let stem = (blendName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "render" : stem
        let sitePart = sanitizeFolderName(siteName, fallback: "Client").replacingOccurrences(of: " ", with: "_")
        let modePart = renderMode == .test ? "Test" : "Rendu"
        return "\(base)_\(sitePart)_\(modePart)_"
    }
}

/// Portage de sanitize_folder_name (project.py) — mêmes caractères acceptés.
public func sanitizeFolderName(_ name: String, fallback: String = "site") -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return fallback }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-. "))
    var result = ""
    for scalar in trimmed.unicodeScalars {
        result.unicodeScalars.append(allowed.contains(scalar) ? scalar : "_")
    }
    return result.isEmpty ? fallback : result
}

// ── persistance JSON (Project.save / load_for_blend) ──

public enum ProjectStore {
    public static let suffix = ".agence_project.json"

    public static func jsonPath(forBlendPath blendPath: String) -> String {
        let dir = (blendPath as NSString).deletingLastPathComponent
        let stem = ((blendPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return (dir as NSString).appendingPathComponent(stem + suffix)
    }

    public static func save(_ project: Project) throws {
        let path = jsonPath(forBlendPath: project.blendPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        let tmpPath = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmpPath))
    }

    /// Charge le projet associé à ce .blend, ou en crée un neuf — JSON
    /// corrompu/absent => projet neuf, jamais une exception qui bloque l'app
    /// (même comportement que Project.load_for_blend côté Python).
    public static func loadOrCreate(forBlendPath blendPath: String) -> Project {
        let path = jsonPath(forBlendPath: blendPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return Project(blendPath: blendPath)
        }
        let decoder = JSONDecoder()
        guard var project = try? decoder.decode(Project.self, from: data) else {
            return Project(blendPath: blendPath)
        }
        project.blendPath = blendPath  // le chemin réel prime toujours sur celui stocké
        return project
    }
}
