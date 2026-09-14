import Foundation

/// Portage de la partie création de projet de main_window.py
/// (_unique_project_path / _start_new_project_from_template) — orchestre
/// TemplateCatalog + Project + ProjectStore, pas de dépendance UI.
public enum ProjectService {
    public static let defaultProjectsRootKey = "projects_root"
    public static let presentationSubfolder = "Vidéo présentation projet"

    /// PAS sous ~/Documents (ni ~/Desktop, ni ~/Downloads) : macOS protège
    /// spécialement ces 3 dossiers (kTCCServiceSystemPolicyDocumentsFolder)
    /// et affiche un popup système "« DigitalMockup » souhaite accéder aux
    /// fichiers de votre dossier Documents" dès qu'un accès disque direct
    /// (hors NSOpenPanel) les touche — repéré le 2026-09-03 : ce popup
    /// apparaissait AU LANCEMENT, avant même que la fenêtre soit visible,
    /// à chaque fois. ~/Movies n'est pas protégé et convient bien au
    /// contenu produit par cette app (vidéos de présentation).
    public static func defaultProjectsRoot() -> String {
        NSString(string: "~/Movies/DigitalMockup — Projets").expandingTildeInPath
    }

    /// <projectsRoot>/Vidéo présentation projet/<nom>[ (N)]/<nom>.blend —
    /// suffixe numérique si ce nom est déjà pris, tant qu'aucun nom de
    /// client n'a encore été choisi (même règle que côté Python).
    public static func uniqueProjectPath(baseName: String, projectsRoot: String) -> String {
        let root = (projectsRoot as NSString).appendingPathComponent(presentationSubfolder)
        let folderName = sanitizeFolderName(baseName, fallback: "Projet")
        let fm = FileManager.default
        var candidate = folderName
        var n = 2
        while true {
            let dir = (root as NSString).appendingPathComponent(candidate)
            let blendPath = (dir as NSString).appendingPathComponent("\(candidate).blend")
            if !fm.fileExists(atPath: blendPath) { break }
            candidate = "\(folderName) (\(n))"
            n += 1
        }
        let dir = (root as NSString).appendingPathComponent(candidate)
        return (dir as NSString).appendingPathComponent("\(candidate).blend")
    }

    /// Crée un nouveau projet à partir d'un template : copie le .blend,
    /// construit le Project (structure de plans figée si le template en a
    /// une et que forceFreeMode est faux — voir Template.presetPlanOrder),
    /// crée 01_CAPTURES/02_RENDUS, sauvegarde le JSON. Ne lance PAS
    /// list_shots (fait séparément, appel Blender potentiellement long).
    public static func createProject(
        from template: Template, projectsRoot: String, forceFreeMode: Bool = false
    ) throws -> Project {
        let destination = uniqueProjectPath(baseName: template.name, projectsRoot: projectsRoot)
        try TemplateCatalog.instantiateTemplate(template, destination: destination)

        var project = Project(blendPath: destination)
        project.templateName = template.name
        project.templateId = template.id

        if let order = template.presetPlanOrder, !forceFreeMode {
            project.pages = [Page(uid: 1, name: "Page 1", cameras: order)]
            project.nextPageUid = 2
            project.locked = true
        }

        let baseDir = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: project.sourcesDir(baseDir: baseDir), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: project.renderDir(baseDir: baseDir), withIntermediateDirectories: true
        )

        try ProjectStore.save(project)
        return project
    }

    /// Résultat de renameProjectToSiteName — un cas par branche de
    /// main_window.py:_rename_project_to_site_name (qui ne lève jamais
    /// d'exception côté Python, juste des messages de statut ; reproduit
    /// ici sans `throws` pour la même raison).
    public enum RenameOutcome {
        /// Rien à renommer (siteName vide, ou déjà à jour).
        case unchanged
        case renamed(Project)
        /// Dossier renommé mais PAS le .blend (ex. cible déjà prise) — le
        /// projet continue avec le nouveau dossier + l'ancien nom de
        /// fichier, pas une erreur bloquante côté Python.
        case renamedWithWarning(Project, String)
        /// Un dossier du nom cible existe déjà — pas de réorganisation.
        case blocked(String)
        /// Le déplacement du dossier lui-même a échoué (droits, etc.).
        case failed(String)
    }

    /// Renomme le dossier du projet ET le .blend (+ son .agence_project.json
    /// à côté) d'après project.siteName — portage direct de
    /// main_window.py:_rename_project_to_site_name (partie disque ; le
    /// debounce de 1200ms après la frappe reste côté UI, voir
    /// AppState.siteNameChanged). Important : Project.outputName() dérive
    /// le nom des rendus du nom du .blend — tant que le fichier reste
    /// "Preset 1.blend", tous les rendus s'appellent "Preset 1_<site>_…"
    /// quel que soit le nom du dossier qui les contient.
    public static func renameProjectToSiteName(_ project: Project) -> RenameOutcome {
        guard !project.blendPath.isEmpty else { return .unchanged }
        let siteName = project.siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !siteName.isEmpty else { return .unchanged }

        let fm = FileManager.default
        let newStem = sanitizeFolderName(siteName, fallback: "Client")
        let oldDir = project.baseDir
        let parentDir = (oldDir as NSString).deletingLastPathComponent
        let newDir = (parentDir as NSString).appendingPathComponent(newStem)
        let oldBlendFilename = (project.blendPath as NSString).lastPathComponent
        let newBlendFilename = newStem + ".blend"

        let dirNeedsRename = (newDir as NSString).standardizingPath != (oldDir as NSString).standardizingPath
        let fileNeedsRename = oldBlendFilename != newBlendFilename
        guard dirNeedsRename || fileNeedsRename else { return .unchanged }

        if dirNeedsRename && fm.fileExists(atPath: newDir) {
            return .blocked("Un dossier '\(newStem)' existe déjà à cet emplacement — pas de réorganisation automatique")
        }

        // Sauvegarde AVANT de bouger quoi que ce soit (_save_now équivalent) —
        // si le déplacement échoue ensuite, le JSON au chemin actuel reste cohérent.
        try? ProjectStore.save(project)
        let oldJSONPath = ProjectStore.jsonPath(forBlendPath: project.blendPath)

        var updated = project
        var currentDir = oldDir

        if dirNeedsRename {
            do {
                try fm.moveItem(atPath: oldDir, toPath: newDir)
            } catch {
                return .failed("Impossible de réorganiser le dossier du projet : \(error.localizedDescription)")
            }
            currentDir = newDir
        }

        // Le .blend et son JSON ont voyagé avec le dossier, sous leur nom d'origine.
        let effectiveOldJSONPath = dirNeedsRename
            ? (currentDir as NSString).appendingPathComponent((oldJSONPath as NSString).lastPathComponent)
            : oldJSONPath

        var warning: String?
        let newBlendPath = (currentDir as NSString).appendingPathComponent(newBlendFilename)
        if fileNeedsRename && !fm.fileExists(atPath: newBlendPath) {
            let oldBlendPath = (currentDir as NSString).appendingPathComponent(oldBlendFilename)
            do {
                try fm.moveItem(atPath: oldBlendPath, toPath: newBlendPath)
                updated.blendPath = newBlendPath
            } catch {
                // Pas une erreur bloquante côté Python : le dossier reste
                // renommé, seul le nom de FICHIER ne suit pas.
                updated.blendPath = oldBlendPath
                warning = "Dossier réorganisé, mais impossible de renommer le .blend : \(error.localizedDescription)"
            }
        } else {
            updated.blendPath = (currentDir as NSString).appendingPathComponent(oldBlendFilename)
        }

        try? ProjectStore.save(updated)

        // Nettoie l'ancien .agence_project.json s'il a changé de nom, pour
        // éviter un doublon orphelin.
        let newJSONPath = ProjectStore.jsonPath(forBlendPath: updated.blendPath)
        if effectiveOldJSONPath != newJSONPath {
            try? fm.removeItem(atPath: effectiveOldJSONPath)
        }

        if let warning { return .renamedWithWarning(updated, warning) }
        return .renamed(updated)
    }

    /// Un projet trouvé sur disque, pour l'écran d'accueil ("Projets
    /// récents"/"Anciens projets") — juste assez d'info pour afficher une
    /// carte/une ligne sans devoir décoder chaque `.agence_project.json`
    /// en entier à chaque redraw.
    public struct ProjectSummary: Identifiable, Sendable, Equatable {
        public var id: String { blendPath }
        public let blendPath: String
        public let displayName: String
        public let lastModified: Date

        public init(blendPath: String, displayName: String, lastModified: Date) {
            self.blendPath = blendPath
            self.displayName = displayName
            self.lastModified = lastModified
        }
    }

    /// Liste les projets client existants sous `<projectsRoot>/Vidéo
    /// présentation projet/`, triés du plus récent au plus ancien (date de
    /// modification du .agence_project.json). Un dossier illisible/corrompu
    /// est simplement ignoré, jamais une erreur qui bloque l'écran d'accueil.
    public static func listRecentProjects(projectsRoot: String) -> [ProjectSummary] {
        let fm = FileManager.default
        let root = (projectsRoot as NSString).appendingPathComponent(presentationSubfolder)
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var summaries: [ProjectSummary] = []
        for entry in entries {
            let projectDir = (root as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectDir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: projectDir),
                  let jsonFile = files.first(where: { $0.hasSuffix(ProjectStore.suffix) }) else { continue }
            let jsonPath = (projectDir as NSString).appendingPathComponent(jsonFile)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
                  let project = try? JSONDecoder().decode(Project.self, from: data) else { continue }

            // Reconstruit le chemin du .blend à partir de l'endroit où ce
            // dossier a RÉELLEMENT été trouvé sur le disque, plutôt que de
            // faire confiance à `project.blendPath` (lu depuis le JSON) —
            // ce champ devient obsolète si tout le dossier `projectsRoot` a
            // été déplacé par un autre moyen que l'app (Finder, script,
            // synchronisation…), constaté le 2026-09-03 : "Cannot read
            // file … No such file or directory" en pointant encore vers
            // l'ancien emplacement après un déplacement manuel. Même
            // convention de nommage que ProjectStore.jsonPath (le .blend a
            // le même "stem" que le .agence_project.json, dans le même
            // dossier) — si jamais introuvable là, on retombe sur le champ
            // du JSON plutôt que d'inventer un chemin faux.
            let stem = String(jsonFile.dropLast(ProjectStore.suffix.count))
            let reconstructedBlendPath = (projectDir as NSString).appendingPathComponent(stem + ".blend")
            let blendPath = fm.fileExists(atPath: reconstructedBlendPath) ? reconstructedBlendPath : project.blendPath

            let modified = (try? fm.attributesOfItem(atPath: jsonPath)[.modificationDate] as? Date) ?? nil
            let displayName = !project.siteName.trimmingCharacters(in: .whitespaces).isEmpty
                ? project.siteName
                : (!project.templateName.isEmpty ? project.templateName : entry)

            summaries.append(ProjectSummary(
                blendPath: blendPath, displayName: displayName, lastModified: modified ?? .distantPast
            ))
        }
        return summaries.sorted { $0.lastModified > $1.lastModified }
    }
}
