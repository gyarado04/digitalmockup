import Foundation

/// Pont vers Blender headless — portage de app/core/blender.py:run_headless
/// et _build_args. blender_side/headless.py lui-même reste INCHANGÉ et reste
/// en Python : c'est le script que Blender exécute dans SON PROPRE
/// interpréteur Python embarqué (`blender -b ... --python headless.py`),
/// pas quelque chose que l'app appelante pourrait remplacer — Blender ne
/// sait scripter qu'en Python. Le portage Swift ne change donc que
/// l'orchestrateur (celui qui lance Blender et lit sa réponse), pas
/// headless.py.
public enum BlenderError: Error, CustomStringConvertible {
    case notFound
    case timeout(seconds: Int)
    case unreadableResponse(tail: String)
    case blenderError(String)

    public var description: String {
        switch self {
        case .notFound:
            return "Blender introuvable dans /Applications — installe Blender.app"
        case .timeout(let seconds):
            return "Blender ne répond pas (timeout \(seconds)s)"
        case .unreadableResponse(let tail):
            return "Réponse Blender illisible : \(tail)"
        case .blenderError(let message):
            return message
        }
    }
}

/// Accumulateur de Data protégé par verrou — pour passer les octets lus
/// depuis la file de lecture dédiée (readQueue) vers le thread appelant
/// sans violer la vérification stricte de concurrence de Swift 6 (un `var`
/// simple capturé et muté depuis une closure @Sendable est refusé à la
/// compilation).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        _data.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }
}

public enum BlenderBridge {
    public static let defaultPath = "/Applications/Blender.app/Contents/MacOS/Blender"

    /// Chemin du binaire Blender — surclassable par AGENCE_BLENDER, comme
    /// côté Python.
    public static func findBlender() -> String? {
        if let override = ProcessInfo.processInfo.environment["AGENCE_BLENDER"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        return FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : nil
    }

    /// blender_side/headless.py — portage de headless_script_path() côté
    /// Python, même repli "frozen" (`sys._MEIPASS`) vs dev : un vrai .app
    /// empaqueté (voir packaging/build_app.sh) l'embarque dans
    /// Contents/Resources/blender_side/, cherché EN PREMIER via
    /// Bundle.main ; sinon (mode dev, `swift run`) on remonte depuis les
    /// sources de CE fichier jusqu'à la racine du projet, qui contient
    /// blender_side/ tel quel.
    public static func headlessScriptPath() -> String {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("blender_side/headless.py")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }
        // Sources/AgenceTemplate3DCore/BlenderBridge.swift
        //   -> .../swift-app/Sources/AgenceTemplate3DCore
        //   -> .../swift-app/Sources
        //   -> .../swift-app
        //   -> racine du projet (contient blender_side/)
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent()  // AgenceTemplate3DCore/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // swift-app/
            .deletingLastPathComponent()  // racine du projet
        return projectRoot.appendingPathComponent("blender_side/headless.py").path
    }

    /// Appel Blender bloquant — à lancer hors du thread principal côté
    /// appelant (SwiftUI : Task.detached / un acteur dédié), jamais
    /// directement dans un handler d'UI. Retourne le dictionnaire JSON du
    /// résultat (voir emit_result côté headless.py).
    @discardableResult
    public static func runHeadless(
        blendPath: String, command: String, config: [String: Any] = [:], timeout: TimeInterval = 180
    ) throws -> [String: Any] {
        guard let blender = findBlender() else { throw BlenderError.notFound }

        let configPath = try writeConfig(config)
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        // `--factory-startup` : démarre sans lire les préférences ni charger
        // les add-ons personnels de l'utilisateur (userpref.blend) — sans ça,
        // un add-on tiers installé globalement dans Blender (ex. BlenderKit)
        // se charge aussi en mode headless et peut planter l'appel (constaté
        // le 2026-09-03 : "Réponse Blender illisible" avec les logs
        // d'enregistrement/désenregistrement de BlenderKit en dernières
        // lignes de stdout — Blender quittait avant d'avoir écrit le
        // résultat). N'affecte QUE l'état de démarrage (add-ons/préférences),
        // pas le fichier .blend chargé via `-b`, qui garde tout son contenu.
        process.arguments = ["-b", "--factory-startup", blendPath, "--python", headlessScriptPath(), "--", command, configPath]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // pas capturé séparément, même choix que côté Python (stderr ignoré ici)

        try process.run()

        // Lit stdout en continu sur une file dédiée PENDANT que le process
        // tourne, pour ne jamais bloquer si la sortie dépasse la taille du
        // buffer du pipe (~64 Ko) avant la fin du process — même risque que
        // côté Python, évité là-bas par subprocess.run(capture_output=True)
        // (communicate() en interne lit aussi en continu). readDataToEndOfFile
        // bloque jusqu'à la fermeture du pipe (= sortie du process), donc
        // tourne sur sa propre file plutôt que le thread appelant.
        let box = DataBox()
        let readQueue = DispatchQueue(label: "blender-stdout-read")
        readQueue.async {
            box.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw BlenderError.timeout(seconds: Int(timeout))
        }
        // Barrière : la file étant sérielle, cette tâche vide n'y passe
        // qu'une fois la lecture ci-dessus terminée (le pipe se ferme dès
        // la fin réelle du process, donc c'est rapide).
        readQueue.sync {}

        let stdout = String(data: box.data, encoding: .utf8) ?? ""
        guard let result = extractResult(from: stdout) else {
            let tail = stdout.split(separator: "\n").suffix(3).joined(separator: " / ")
            throw BlenderError.unreadableResponse(tail: tail)
        }
        if (result["ok"] as? Bool) != true {
            throw BlenderError.blenderError(result["error"] as? String ?? "Erreur Blender inconnue")
        }
        return result
    }

    /// Extrait le dernier bloc AGENCE_RESULT_BEGIN…AGENCE_RESULT_END du
    /// stdout — même marqueur que RESULT_RE côté app/core/blender.py.
    public static func extractResult(from stdout: String) -> [String: Any]? {
        guard let beginRange = stdout.range(of: "AGENCE_RESULT_BEGIN", options: .backwards),
              let endRange = stdout.range(of: "AGENCE_RESULT_END", options: .backwards),
              beginRange.upperBound <= endRange.lowerBound else {
            return nil
        }
        let jsonString = String(stdout[beginRange.upperBound..<endRange.lowerBound])
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Pas `private` : réutilisé tel quel par RenderProcess (même format de
    /// fichier de config temporaire, même convention côté headless.py).
    static func writeConfig(_ config: [String: Any]) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agence_config_\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}
