import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Rendu animé en arrière-plan — portage direct de
/// app/core/blender.py:RenderProcess (qui utilise QProcess côté Python).
/// Lance `blender -b <blend> --python headless.py -- render <config.json>`
/// et parse son stdout EN CONTINU (pas un appel bloquant comme
/// BlenderBridge.runHeadless — un rendu dure potentiellement plusieurs
/// minutes, l'app doit afficher une progression pendant ce temps).
///
/// Mêmes marqueurs texte que côté Python, émis par blender_side/headless.py
/// (INCHANGÉ des deux côtés, voir cmd_render) :
///   AGENCE_PROGRESS <frame Blender réelle> <compteur virtuel> <total virtuel>
///   AGENCE_PREVIEW <frame>            — un PNG d'aperçu vient d'être écrit
///   AGENCE_RESULT_BEGIN{...}AGENCE_RESULT_END   — stage "render_start"/"render_done"
///
/// Callbacks plutôt que Combine/delegate : Core n'a aucune dépendance
/// SwiftUI, c'est à l'appelant (AppState, @MainActor) de re-poster sur le
/// thread principal si besoin — ces callbacks sont invoqués depuis la file
/// de lecture interne du pipe, PAS le thread principal.
public struct RenderProgress: Sendable {
    public let frame: Int
    public let frameStart: Int
    public let frameEnd: Int
    /// < 0 tant que pas encore estimable (même convention que côté Python).
    public let etaSeconds: Double
}

public final class RenderProcess: @unchecked Sendable {
    public var onProgress: (@Sendable (RenderProgress) -> Void)?
    public var onPreviewUpdated: (@Sendable (Int) -> Void)?
    public var onLogLine: (@Sendable (String) -> Void)?
    /// (ok, message) — appelé exactement une fois, à la toute fin (succès,
    /// échec ou annulation).
    public var onFinished: (@Sendable (Bool, String) -> Void)?

    // Tout ce qui suit est muté depuis plusieurs threads (le thread
    // appelant pour start()/cancel(), la file interne du Pipe pour la
    // lecture du stdout, une file arbitraire pour terminationHandler) —
    // protégé par ce verrou, même raison que DataBox dans BlenderBridge.
    private let lock = NSLock()
    private var process: Process?
    private var pipe: Pipe?
    private var configPath: String?
    private var lineBuffer = ""
    private var stdoutTail = ""
    private var cancelled = false
    private var renderDone = false
    private var frameStart = 1
    private var frameEnd = 900
    private var renderStartTime: DispatchTime?

    private static let progressRegex = try! NSRegularExpression(pattern: "^AGENCE_PROGRESS (\\d+) (\\d+) (\\d+)")

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public func start(blendPath: String, config: [String: Any]) throws {
        lock.lock()
        let alreadyRunning = process?.isRunning ?? false
        lock.unlock()
        if alreadyRunning {
            throw BlenderError.blenderError("Un rendu est déjà en cours")
        }
        guard let blender = BlenderBridge.findBlender() else {
            throw BlenderError.notFound
        }
        let configPath = try BlenderBridge.writeConfig(config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        // `--factory-startup` : voir le commentaire équivalent dans
        // BlenderBridge.runHeadless — évite qu'un add-on tiers de
        // l'utilisateur (BlenderKit, etc.) interfère avec un rendu headless.
        process.arguments = ["-b", "--factory-startup", blendPath, "--python", BlenderBridge.headlessScriptPath(), "--", "render", configPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe  // MergedChannels côté Python

        lock.lock()
        self.process = process
        self.pipe = pipe
        self.configPath = configPath
        lineBuffer = ""
        stdoutTail = ""
        cancelled = false
        renderDone = false
        frameStart = 1
        frameEnd = 900
        renderStartTime = nil
        lock.unlock()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.handleOutput(text)
        }
        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(exitCode: proc.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            lock.lock()
            self.process = nil
            self.pipe = nil
            lock.unlock()
            try? FileManager.default.removeItem(atPath: configPath)
            throw error
        }
    }

    /// Annulation SYNCHRONE — bloque jusqu'à confirmation que Blender est
    /// bien mort (SIGTERM, puis SIGKILL après 3s s'il s'accroche), même
    /// choix que côté Python : jamais de process Blender orphelin en
    /// arrière-plan, quitte à faire attendre l'appelant quelques secondes.
    public func cancel() {
        lock.lock()
        guard let process, process.isRunning else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()

        process.terminate()
        let termDeadline = DispatchTime.now() + .seconds(3)
        while process.isRunning && DispatchTime.now() < termDeadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = DispatchTime.now() + .seconds(2)
            while process.isRunning && DispatchTime.now() < killDeadline {
                usleep(50_000)
            }
        }
    }

    // ── lecture du stdout ──

    private func handleOutput(_ text: String) {
        var completeLines: [String] = []
        lock.lock()
        lineBuffer += text
        stdoutTail += text
        // Ne garde que la fin du buffer (les marqueurs utiles y sont) —
        // même limite que côté Python.
        if stdoutTail.count > 200_000 {
            stdoutTail = String(stdoutTail.suffix(100_000))
        }
        // Ne traite que des lignes complètes — un chunk peut couper une
        // ligne (et donc un marqueur AGENCE_*) en plein milieu.
        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            completeLines.append(String(lineBuffer[lineBuffer.startIndex..<newlineIndex]))
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
        }
        lock.unlock()

        for line in completeLines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            process(line: line)
        }
    }

    private func process(line: String) {
        onLogLine?(line)

        let fullRange = NSRange(line.startIndex..., in: line)
        if let match = Self.progressRegex.firstMatch(in: line, range: fullRange),
           let counterRange = Range(match.range(at: 2), in: line),
           let counter = Int(line[counterRange]) {
            let (fs, fe, eta): (Int, Int, Double) = {
                lock.lock()
                defer { lock.unlock() }
                return (frameStart, frameEnd, computeETA(frame: counter))
            }()
            onProgress?(RenderProgress(frame: counter, frameStart: fs, frameEnd: fe, etaSeconds: eta))
            return
        }

        if line.hasPrefix("AGENCE_PREVIEW") {
            let parts = line.split(separator: " ")
            if parts.count > 1, let frame = Int(parts[1]) {
                onPreviewUpdated?(frame)
            }
            return
        }

        if line.contains("AGENCE_RESULT_BEGIN"), let result = BlenderBridge.extractResult(from: line) {
            let stage = result["stage"] as? String
            if stage == "render_start" {
                lock.lock()
                frameStart = result["frame_start"] as? Int ?? 1
                frameEnd = result["frame_end"] as? Int ?? 900
                renderStartTime = DispatchTime.now()
                lock.unlock()
            } else if stage == "render_done" {
                lock.lock()
                renderDone = true
                lock.unlock()
            }
        }
    }

    /// Débit observé depuis le début du rendu -> temps restant estimé (s).
    /// Appelée avec `lock` déjà tenu par l'appelant (lit renderStartTime
    /// directement) — même règle que _estimate_eta côté Python.
    private func computeETA(frame: Int) -> Double {
        guard let start = renderStartTime else { return -1.0 }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        let framesDone = frame - frameStart + 1
        let total = frameEnd - frameStart + 1
        guard elapsed > 0, framesDone > 0 else { return -1.0 }
        let rate = Double(framesDone) / elapsed
        let remaining = max(0, total - framesDone)
        return rate > 0 ? Double(remaining) / rate : -1.0
    }

    // ── fin de process ──

    private func handleTermination(exitCode: Int32) {
        pipe?.fileHandleForReading.readabilityHandler = nil

        let (wasCancelled, done, path, tail) = { () -> (Bool, Bool, String?, String) in
            lock.lock()
            defer { lock.unlock() }
            return (cancelled, renderDone, configPath, stdoutTail)
        }()

        if let path {
            try? FileManager.default.removeItem(atPath: path)
        }
        lock.lock()
        configPath = nil
        process = nil
        pipe = nil
        lock.unlock()

        if wasCancelled {
            onFinished?(false, "Rendu annulé")
        } else if done && exitCode == 0 {
            onFinished?(true, "Rendu terminé")
        } else if let result = BlenderBridge.extractResult(from: tail),
                  (result["ok"] as? Bool) != true,
                  let error = result["error"] as? String {
            onFinished?(false, "Échec du rendu : \(error)")
        } else {
            onFinished?(false, "Blender s'est arrêté (code \(exitCode))")
        }
    }
}
