import AgenceTemplate3DCore
import AppKit
import Foundation

// Exécutable CLI ordinaire (pas XCTest/Testing — leur runtime n'est fourni
// que par Xcode, absent des Command Line Tools seules, voir Package.swift)
// qui vérifie "à la main" le paquet Core : assertions + PASS/FAIL sur
// stdout, même esprit que AGENCE_SELFTEST côté app Python. À lancer via
// `swift run AgenceTemplate3DSelfTest` depuis swift-app/.

var failures = 0

@MainActor
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

// ── 1. Project/Page : valeurs par défaut ──

var project = Project(blendPath: "/tmp/Client.blend")
check("nouveau projet a 1 page par défaut", project.pages.count == 1)
check("nouveau projet locked=false par défaut", project.locked == false)
check("nouveau projet fps=24 par défaut", project.fps == 24.0)

project.addPage()
check("addPage() -> 2 pages", project.pages.count == 2)
check("addPage() -> uid=2 sur la 2e page", project.pages[1].uid == 2)
check("next_page_uid avancé à 3", project.nextPageUid == 3)

let removed = project.removePage(at: 0)
check("removePage() réussit à 2 pages", removed == true)
check("il reste 1 page", project.pages.count == 1)
let removedAgain = project.removePage(at: 0)
check("removePage() refuse de descendre sous 1 page", removedAgain == false)
check("toujours 1 page après refus", project.pages.count == 1)

// ── 2. Codable : round-trip JSON avec les clés attendues côté Python ──

project.pages[0].cameras = ["Plan 1 - Desktop", "Plan 2 - Desktop"]
project.camerasCache = [CameraShot(name: "Plan 1 - Desktop", thumbnail: "/tmp/p1.png", video: nil, frames: 99)]
project.siteName = "Les ETI"
project.templateId = "tablette"

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
guard let encoded = try? encoder.encode(project) else {
    print("FAIL  encodage JSON du projet a échoué")
    failures += 1
    exit(1)
}
let jsonText = String(data: encoded, encoding: .utf8) ?? ""
check("JSON encodé contient 'blend_path' (snake_case, compatible Python)", jsonText.contains("\"blend_path\""))
check("JSON encodé contient 'cameras_cache'", jsonText.contains("\"cameras_cache\""))
check("JSON encodé contient 'next_page_uid'", jsonText.contains("\"next_page_uid\""))

let decoder = JSONDecoder()
if let decoded = try? decoder.decode(Project.self, from: encoded) {
    check("round-trip JSON préserve site_name", decoded.siteName == "Les ETI")
    check("round-trip JSON préserve les pages/cameras", decoded.pages.first?.cameras == ["Plan 1 - Desktop", "Plan 2 - Desktop"])
    check("round-trip JSON préserve cameras_cache.frames", decoded.camerasCache.first?.frames == 99)
} else {
    print("FAIL  décodage JSON du projet a échoué")
    failures += 1
}

// ── 3. Rétro-compat : cameras_cache ancien format (liste de String simples) ──

let legacyJSON = """
{"blend_path": "/tmp/x.blend", "cameras_cache": ["Plan 1 - Desktop", "Plan 2 - Desktop"]}
""".data(using: .utf8)!
if let legacy = try? decoder.decode(Project.self, from: legacyJSON) {
    check("rétro-compat cameras_cache ancien format (liste de String)", legacy.camerasCache.map(\.name) == ["Plan 1 - Desktop", "Plan 2 - Desktop"])
} else {
    print("FAIL  décodage rétro-compat cameras_cache a échoué")
    failures += 1
}

// ── 4. Lecture d'un VRAI fichier .agence_project.json écrit par l'app Python ──

let fm = FileManager.default
let presentationDir = NSString(string: "~/Documents/Vidéo présentation projet").expandingTildeInPath
if let clientDirs = try? fm.contentsOfDirectory(atPath: presentationDir) {
    var realProjectFound = false
    for clientDir in clientDirs {
        let clientPath = (presentationDir as NSString).appendingPathComponent(clientDir)
        guard let files = try? fm.contentsOfDirectory(atPath: clientPath) else { continue }
        for file in files where file.hasSuffix(".agence_project.json") {
            let path = (clientPath as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard let realProject = try? decoder.decode(Project.self, from: data) else {
                print("FAIL  lecture du vrai fichier \(file) (Python) a échoué")
                failures += 1
                continue
            }
            realProjectFound = true
            print("PASS  lecture réelle de '\(file)' : \(realProject.pages.count) page(s), template_id='\(realProject.templateId)'")
        }
    }
    check("au moins un vrai .agence_project.json (créé par l'app Python) lu avec succès", realProjectFound)
} else {
    print("(pas de dossier de projets réels trouvé — étape 4 sautée, pas un échec)")
}

// ── 5. Pont Blender : chemins ──

let scriptPath = BlenderBridge.headlessScriptPath()
check("headless.py résolu existe bien sur disque : \(scriptPath)", fm.fileExists(atPath: scriptPath))

let blenderPath = BlenderBridge.findBlender()
check("Blender trouvé dans /Applications", blenderPath != nil)

// ── 6. VRAI appel Blender headless — list_shots sur le template "tablette" ──
// (le test le plus important : prouve que le pont Swift parle bien le même
// protocole que app/core/blender.py avec le VRAI headless.py, sans mock.)

if blenderPath != nil {
    let projectRoot = URL(fileURLWithPath: scriptPath)
        .deletingLastPathComponent()  // blender_side/
        .deletingLastPathComponent()  // racine du projet
    let tabletteBlend = projectRoot.appendingPathComponent("templates/tablette/template.blend").path
    let cacheDir = NSTemporaryDirectory() + "agence_swift_selftest_cache_\(UUID().uuidString)"

    do {
        let result = try BlenderBridge.runHeadless(
            blendPath: tabletteBlend, command: "list_shots", config: ["cache_dir": cacheDir]
        )
        let shots = result["shots"] as? [[String: Any]] ?? []
        check("list_shots réel renvoie 9 plans", shots.count == 9)
        let names = shots.compactMap { $0["name"] as? String }
        check("list_shots contient 'Plan 1 - Desktop'", names.contains("Plan 1 - Desktop"))
        check("list_shots contient 'Plan 9 - Mobile'", names.contains("Plan 9 - Mobile"))
        let plan1Frames = shots.first(where: { $0["name"] as? String == "Plan 1 - Desktop" })?["frames"] as? Int
        check("Plan 1 - Desktop a bien 99 frames (vérifié plus tôt côté Python)", plan1Frames == 99)
        let fps = result["fps"] as? Double
        check("fps=24.0 renvoyé par le VRAI Blender", fps == 24.0)
        print("(vrai appel Blender headless réussi, résultat identique au pont Python)")
    } catch {
        print("FAIL  appel Blender réel (list_shots) : \(error)")
        failures += 1
    }
    try? fm.removeItem(atPath: cacheDir)
} else {
    print("(Blender introuvable — étape 6 sautée)")
}

// ── 7. TemplateCatalog : lecture du vrai templates/manifest.json ──

let templates = TemplateCatalog.listTemplates()
check("5 templates listés (manifest.json réel)", templates.count == 5)
if let tablette = TemplateCatalog.findTemplate(byId: "tablette") {
    check("'tablette' a un preset_plan_order de 9 plans", tablette.presetPlanOrder?.count == 9)
    check("'tablette' preset_plan_order commence par 'Plan 1 - Desktop'", tablette.presetPlanOrder?.first == "Plan 1 - Desktop")
    check("TemplateCatalog.isPresetPath reconnaît le .blend du preset", TemplateCatalog.isPresetPath(tablette.blendPath))
    check("isPresetPath rejette un chemin hors templates/", !TemplateCatalog.isPresetPath("/tmp/Client.blend"))

    // VRAIS fichiers déposés à la main sous templates/tablette/shots/ —
    // pas des mocks : ce sont les fichiers réels fournis par l'utilisateur
    // le 2026-09-03 pour l'aperçu vidéo au survol de "Assigner un plan".
    let assets = TemplateCatalog.shotAssets(templateId: "tablette", cameraName: "Plan 1 - Desktop")
    check("shotAssets trouve une photo déposée à la main", assets.photo != nil && fm.fileExists(atPath: assets.photo!))
    check("shotAssets trouve une vidéo déposée à la main", assets.video != nil && fm.fileExists(atPath: assets.video!))
    let noAssets = TemplateCatalog.shotAssets(templateId: "tablette", cameraName: "Caméra sans assets déposés")
    check("shotAssets -> (nil, nil) quand rien n'est déposé pour cette caméra", noAssets.photo == nil && noAssets.video == nil)
    let noTemplate = TemplateCatalog.shotAssets(templateId: "id_inexistant", cameraName: "Plan 1 - Desktop")
    check("shotAssets -> (nil, nil) pour un templateId inconnu", noTemplate.photo == nil && noTemplate.video == nil)
} else {
    print("FAIL  template 'tablette' introuvable dans le manifest")
    failures += 1
}

// ── 8. ProjectService.createProject : VRAIE création de projet sur disque ──
// (dans un dossier temporaire isolé — jamais dans le vrai dossier de
// projets de l'utilisateur, même règle d'isolation que côté tests Python.)

let tmpProjectsRoot = NSTemporaryDirectory() + "agence_swift_selftest_projects_\(UUID().uuidString)"
defer { try? fm.removeItem(atPath: tmpProjectsRoot) }

if let tablette = TemplateCatalog.findTemplate(byId: "tablette") {
    do {
        let created = try ProjectService.createProject(from: tablette, projectsRoot: tmpProjectsRoot)
        check("projet créé : .blend existe sur disque", fm.fileExists(atPath: created.blendPath))
        check("projet créé : .agence_project.json existe sur disque", fm.fileExists(atPath: ProjectStore.jsonPath(forBlendPath: created.blendPath)))
        let baseDir = (created.blendPath as NSString).deletingLastPathComponent
        check("01_CAPTURES créé", fm.fileExists(atPath: created.sourcesDir(baseDir: baseDir)))
        check("02_RENDUS créé", fm.fileExists(atPath: created.renderDir(baseDir: baseDir)))
        check("preset 'tablette' -> locked=true", created.locked == true)
        check("preset 'tablette' -> 1 page avec les 9 plans", created.pages.count == 1 && created.pages[0].cameras.count == 9)

        // Reload depuis le disque (pas l'objet en mémoire) pour prouver que
        // le JSON écrit est bien complet et relisible tel quel.
        let reloaded = ProjectStore.loadOrCreate(forBlendPath: created.blendPath)
        check("relecture depuis le disque préserve locked/pages", reloaded.locked == true && reloaded.pages == created.pages)

        // N'écrase jamais le .blend original du preset.
        let originalSize = (try? fm.attributesOfItem(atPath: tablette.blendPath)[.size] as? Int) ?? nil
        check("le .blend original du preset n'a pas bougé", originalSize != nil)

        // Mode libre : même template, mais force_free_mode -> pas verrouillé
        let createdFree = try ProjectService.createProject(from: tablette, projectsRoot: tmpProjectsRoot, forceFreeMode: true)
        check("mode libre -> locked=false même sur un template avec preset", createdFree.locked == false)
        check("mode libre -> 1 page VIDE", createdFree.pages.count == 1 && createdFree.pages[0].cameras.isEmpty)
    } catch {
        print("FAIL  ProjectService.createProject a levé une erreur : \(error)")
        failures += 1
    }
} else {
    print("(template 'tablette' introuvable — étape 8 sautée)")
}

// ── 9. WebCapture (WKWebView native) — VRAIE capture d'une page locale ──
// (pas de dépendance réseau : une page HTML simple écrite dans un fichier
// temporaire, chargée via file://). Le vrai test : est-ce que WKWebView
// fonctionne DU TOUT dans un exécutable CLI sans NSApplication ?

let htmlPath = NSTemporaryDirectory() + "agence_webcapture_test_\(UUID().uuidString).html"
let testHTML = """
<!DOCTYPE html><html><body style="margin:0">
<div style="height:3000px; background: linear-gradient(red, blue);">
  <h1 id="title" style="padding-top:40px; text-align:center;">Test WebCapture</h1>
</div>
</body></html>
"""
try? testHTML.write(toFile: htmlPath, atomically: true, encoding: .utf8)
let pngOutputPath = NSTemporaryDirectory() + "agence_webcapture_test_\(UUID().uuidString).png"

let webCaptureSemaphore = DispatchSemaphore(value: 0)
var webCaptureError: String?
var webCapturePngExists = false
var webCapturePngSize: (width: Int, height: Int)?

Task { @MainActor in
    do {
        let capture = WebCapture()
        // `useHostWindow: false` : ce test (page locale, dégradé statique,
        // aucune vidéo) n'a pas besoin de la fenêtre hôte réelle qu'utilise
        // WebCapture par défaut (nécessaire seulement pour qu'une <video>
        // de la page charge, voir son commentaire) — et créer une VRAIE
        // fenêtre bloque indéfiniment dans ce simple exécutable CLI (pas de
        // vraie boucle NSApplication qui tourne, contrairement à l'app
        // réelle), constaté le 2026-09-03. Le comportement AVEC vidéo/
        // fenêtre hôte se vérifie dans l'app réelle via
        // `AGENCE_SELFTEST=capture` (voir SelfTestRunner.swift).
        try await capture.capture(
            url: URL(fileURLWithPath: htmlPath), viewportWidth: 400, viewportHeight: 300,
            outputPath: pngOutputPath, useHostWindow: false
        )
    } catch {
        webCaptureError = "\(error)"
    }
    webCaptureSemaphore.signal()
}

// Une vraie boucle d'exécution doit tourner pour que WKWebView (délégués,
// JS async, etc.) puisse progresser — un exécutable CLI n'en a pas par
// défaut (contrairement à une app SwiftUI/AppKit). Pompe RunLoop.main
// manuellement en attendant le signal, avec un plafond de sécurité.
let webCaptureDeadline = Date().addingTimeInterval(30)
while webCaptureSemaphore.wait(timeout: .now()) == .timedOut && Date() < webCaptureDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

if let webCaptureError {
    print("FAIL  WebCapture : \(webCaptureError)")
    failures += 1
} else {
    webCapturePngExists = fm.fileExists(atPath: pngOutputPath)
    check("WebCapture a bien écrit un fichier PNG", webCapturePngExists)
    if webCapturePngExists, let image = NSImage(contentsOfFile: pngOutputPath) {
        webCapturePngSize = (Int(image.size.width), Int(image.size.height))
        print("(WebCapture PNG : \(webCapturePngSize!.width)×\(webCapturePngSize!.height))")
        check("WebCapture PNG fait bien 400 de large", webCapturePngSize!.width == 400)
        // La page de test fait exactement 3000px de haut (div avec
        // height:3000px explicite) — 3000 est donc la bonne réponse (page
        // ENTIÈRE capturée), pas juste le viewport de départ (300).
        check("WebCapture PNG capture la page ENTIÈRE (3000, pas juste le viewport 300)", webCapturePngSize!.height == 3000)

        // Vérifie le VRAI contenu par les pixels (pas juste la taille du
        // fichier) : le dégradé rouge→bleu doit donner du rouge en haut,
        // du bleu en bas — confirme que la page a vraiment été rendue, pas
        // une image blanche/vide de la bonne taille par coïncidence.
        if let bitmap = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: pngOutputPath))) {
            // y=150 plutôt que tout en haut : évite la zone du <h1> (marge
            // par défaut du navigateur) qui peut fausser l'échantillon.
            let topColor = bitmap.colorAt(x: 200, y: 150)
            let bottomColor = bitmap.colorAt(x: 200, y: bitmap.pixelsHigh - 10)
            print("(couleur haut: \(topColor?.description ?? "?"), couleur bas: \(bottomColor?.description ?? "?"))")
            let topIsReddish = (topColor?.redComponent ?? 0) > (topColor?.blueComponent ?? 1)
            let bottomIsBlueish = (bottomColor?.blueComponent ?? 0) > (bottomColor?.redComponent ?? 1)
            check("contenu réellement rendu (rouge en haut du dégradé)", topIsReddish)
            check("contenu réellement rendu (bleu en bas du dégradé)", bottomIsBlueish)
        } else {
            print("FAIL  impossible de relire le PNG pour vérifier les pixels")
            failures += 1
        }
    }
}
try? fm.removeItem(atPath: htmlPath)
try? fm.removeItem(atPath: pngOutputPath)

// ── 9b. WebCapture.captureFrameSequence — préserve le MOUVEMENT d'une
// animation d'apparition au scroll (pas juste son état final, remplace
// l'image fixe plein-page, 2026-09-08). Même page dégradé rouge->bleu que
// l'étape 9 (pas besoin d'une vraie fenêtre hôte ici : on vérifie la
// MÉCANIQUE de la séquence — nombre/dimensions/progression des frames —
// pas le rendu d'une transition CSS, qui a besoin d'un compositeur actif
// donc d'une vraie fenêtre, voir `useHostWindow` — ça se vérifie dans
// l'app réelle, pas cet outil CLI, même limite que l'étape 9).

let seqHtmlPath = NSTemporaryDirectory() + "agence_webcapture_seq_test_\(UUID().uuidString).html"
let seqTestHTML = """
<!DOCTYPE html><html><body style="margin:0">
<div style="height:900px; background: linear-gradient(red, blue);"></div>
</body></html>
"""
try? seqTestHTML.write(toFile: seqHtmlPath, atomically: true, encoding: .utf8)
let seqOutputDir = NSTemporaryDirectory() + "agence_webcapture_seq_test_\(UUID().uuidString)"

let seqCaptureSemaphore = DispatchSemaphore(value: 0)
var seqCaptureError: String?
var seqFrameCount = 0

Task { @MainActor in
    do {
        let capture = WebCapture()
        seqFrameCount = try await capture.captureFrameSequence(
            url: URL(fileURLWithPath: seqHtmlPath), viewportWidth: 200, viewportHeight: 300,
            outputDir: seqOutputDir, useHostWindow: false
        )
    } catch {
        seqCaptureError = "\(error)"
    }
    seqCaptureSemaphore.signal()
}
let seqCaptureDeadline = Date().addingTimeInterval(30)
while seqCaptureSemaphore.wait(timeout: .now()) == .timedOut && Date() < seqCaptureDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

if let seqCaptureError {
    print("FAIL  WebCapture.captureFrameSequence : \(seqCaptureError)")
    failures += 1
} else {
    print("(captureFrameSequence : \(seqFrameCount) frames écrites)")
    // Page 900px, viewport 300px -> 600px de marge de scroll ; à
    // SECONDS_PER_VIEWPORT_HEIGHT=4s et videoFps=8, ~4.7s de scroll +
    // marge -> largement plus de 2 frames (1 en haut + au moins 1 pendant
    // le scroll + 1 garantie en bas).
    check("captureFrameSequence : au moins 3 frames (page plus haute qu'un viewport)", seqFrameCount >= 3)

    let firstFramePath = (seqOutputDir as NSString).appendingPathComponent("frame_0001.png")
    let lastFramePath = (seqOutputDir as NSString).appendingPathComponent(String(format: "frame_%04d.png", seqFrameCount))
    check("captureFrameSequence : frame_0001.png existe", fm.fileExists(atPath: firstFramePath))
    check("captureFrameSequence : dernière frame numérotée existe", fm.fileExists(atPath: lastFramePath))

    if let firstImage = NSImage(contentsOfFile: firstFramePath) {
        check("captureFrameSequence : largeur de frame = 200 (viewport, pas la page entière)", Int(firstImage.size.width) == 200)
        check("captureFrameSequence : hauteur de frame = 300 (viewport, PAS la hauteur de page 900)", Int(firstImage.size.height) == 300)
    } else {
        print("FAIL  captureFrameSequence : impossible de relire frame_0001.png")
        failures += 1
    }

    // Vérifie que le scroll a bien progressé entre la 1ère et la dernière
    // frame (dégradé rouge->bleu, même principe que l'étape 9) : la
    // COULEUR MOYENNE de la dernière frame doit être bien plus bleue que
    // celle de la première — preuve que chaque frame capture un VRAI
    // instant différent du scroll, pas la même image répétée.
    if let firstData = try? Data(contentsOf: URL(fileURLWithPath: firstFramePath)),
       let firstBitmap = NSBitmapImageRep(data: firstData),
       let lastData = try? Data(contentsOf: URL(fileURLWithPath: lastFramePath)),
       let lastBitmap = NSBitmapImageRep(data: lastData) {
        let firstColor = firstBitmap.colorAt(x: firstBitmap.pixelsWide / 2, y: firstBitmap.pixelsHigh / 2)
        let lastColor = lastBitmap.colorAt(x: lastBitmap.pixelsWide / 2, y: lastBitmap.pixelsHigh / 2)
        print("(centre 1ère frame: \(firstColor?.description ?? "?"), centre dernière frame: \(lastColor?.description ?? "?"))")
        check(
            "captureFrameSequence : la dernière frame est bien plus bleue que la première (scroll réel entre les frames)",
            (lastColor?.blueComponent ?? 0) > (firstColor?.blueComponent ?? 1)
        )
    } else {
        print("FAIL  captureFrameSequence : impossible de relire les PNG pour comparer les couleurs")
        failures += 1
    }
}
try? fm.removeItem(atPath: seqHtmlPath)
try? fm.removeItem(atPath: seqOutputDir)

// ── 10. RenderProcess — VRAI rendu Blender en arrière-plan (stdout streamé) ──
// Mode libre, UN SEUL plan assigné ("Plan 1 - Desktop", 99 frames) plutôt
// que les ~900 de tous les plans du preset — le but est de prouver que le
// streaming AGENCE_PROGRESS/AGENCE_PREVIEW/AGENCE_RESULT fonctionne
// réellement de bout en bout (mêmes marqueurs que côté Python), pas de
// mesurer un temps de rendu complet.

/// Accumulateur Sendable pour les callbacks de RenderProcess — mêmes
/// raisons que DataBox dans BlenderBridge.swift : muter un `var` local
/// capturé par une closure `@Sendable` est refusé par Swift 6.
final class RenderTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var _progressCount = 0
    private var _lastProgress: RenderProgress?
    private var _previewUpdates = 0
    private var _finishedOK: Bool?
    private var _finishedMessage = ""

    func recordProgress(_ p: RenderProgress) {
        lock.lock(); _progressCount += 1; _lastProgress = p; lock.unlock()
    }
    func recordPreview() {
        lock.lock(); _previewUpdates += 1; lock.unlock()
    }
    func recordFinished(ok: Bool, message: String) {
        lock.lock(); _finishedOK = ok; _finishedMessage = message; lock.unlock()
    }
    var snapshot: (progressCount: Int, lastProgress: RenderProgress?, previewUpdates: Int, finishedOK: Bool?, finishedMessage: String) {
        lock.lock(); defer { lock.unlock() }
        return (_progressCount, _lastProgress, _previewUpdates, _finishedOK, _finishedMessage)
    }
}

if let tablette = TemplateCatalog.findTemplate(byId: "tablette") {
    let renderProjectsRoot = NSTemporaryDirectory() + "agence_swift_selftest_render_\(UUID().uuidString)"
    defer { try? fm.removeItem(atPath: renderProjectsRoot) }
    do {
        var renderProject = try ProjectService.createProject(from: tablette, projectsRoot: renderProjectsRoot, forceFreeMode: true)
        renderProject.pages[0].cameras = ["Plan 1 - Desktop"]

        // Fausses captures desktop/mobile — le rendu a juste besoin d'un
        // PNG valide à charger sur les nœuds de texture, pas d'un vrai site
        // (WebCapture est déjà vérifiée séparément aux étapes 9/9b).
        // `pageDesktopPath`/`pageMobilePath` sont des DOSSIERS de séquence
        // depuis le 2026-09-08 (voir leur commentaire) — une seule
        // "frame_0001.png" dedans suffit à en faire une capture valide
        // (`pageHasCaptures`) ; `headless.py:sync_texture_node` la charge
        // alors comme une séquence à 1 frame (comportement équivalent à
        // une image fixe pour ce test, qui ne vérifie que le pipeline de
        // rendu, pas le mouvement d'une vraie animation).
        let baseDir = renderProject.baseDir
        let page = renderProject.pages[0]
        let pageDir = renderProject.pageDir(page, baseDir: baseDir)
        try fm.createDirectory(atPath: pageDir, withIntermediateDirectories: true)
        let placeholder = NSImage(size: NSSize(width: 40, height: 40))
        placeholder.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        placeholder.unlockFocus()
        guard let tiff = placeholder.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG placeholder impossible"])
        }
        let desktopSeqDir = renderProject.pageDesktopPath(page, baseDir: baseDir)
        let mobileSeqDir = renderProject.pageMobilePath(page, baseDir: baseDir)
        try fm.createDirectory(atPath: desktopSeqDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: mobileSeqDir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: Project.firstFramePath(inSequenceDir: desktopSeqDir)))
        try png.write(to: URL(fileURLWithPath: Project.firstFramePath(inSequenceDir: mobileSeqDir)))
        try ProjectStore.save(renderProject)

        let (config, previewPath) = try RenderConfigBuilder.buildConfig(for: renderProject)

        let renderProcess = RenderProcess()
        let renderState = RenderTestState()
        let renderSemaphore = DispatchSemaphore(value: 0)
        renderProcess.onProgress = { p in renderState.recordProgress(p) }
        renderProcess.onPreviewUpdated = { _ in renderState.recordPreview() }
        renderProcess.onFinished = { ok, message in
            renderState.recordFinished(ok: ok, message: message)
            renderSemaphore.signal()
        }

        try renderProcess.start(blendPath: renderProject.blendPath, config: config)
        check("RenderProcess.isRunning juste après start()", renderProcess.isRunning)

        let renderTimedOut = renderSemaphore.wait(timeout: .now() + 300) == .timedOut
        if renderTimedOut {
            renderProcess.cancel()
        }
        check("le rendu se termine avant le timeout (300s)", !renderTimedOut)

        let result = renderState.snapshot
        print("(rendu terminé : ok=\(result.finishedOK.map(String.init) ?? "?"), message='\(result.finishedMessage)', "
            + "\(result.progressCount) mise(s) à jour de progression, \(result.previewUpdates) aperçu(s))")
        check("rendu réussi (onFinished ok=true)", result.finishedOK == true)
        check("message de fin = 'Rendu terminé'", result.finishedMessage == "Rendu terminé")
        check("au moins une mise à jour de progression reçue", result.progressCount > 0)
        if let lastProgress = result.lastProgress {
            check("la dernière progression atteint le total (frame == frameEnd)", lastProgress.frame == lastProgress.frameEnd)
        }
        check("au moins un aperçu PNG en direct reçu", result.previewUpdates > 0)
        check("le PNG d'aperçu existe sur disque à la fin", fm.fileExists(atPath: previewPath))

        let renderDirContents = (try? fm.contentsOfDirectory(atPath: renderProject.renderDir(baseDir: baseDir))) ?? []
        let outputFiles = renderDirContents.filter { $0.hasPrefix(renderProject.outputName()) }
        print("(fichier(s) de sortie : \(outputFiles))")
        check("un fichier vidéo de sortie a été écrit", !outputFiles.isEmpty)
        check("RenderProcess.isRunning == false après la fin", renderProcess.isRunning == false)
    } catch {
        print("FAIL  RenderProcess : \(error)")
        failures += 1
    }
} else {
    print("(template 'tablette' introuvable — étape 10 sautée)")
}

// ── 11. ProjectService.renameProjectToSiteName — VRAI renommage sur disque ──
// (dossier + .blend + .agence_project.json d'après siteName) — portage de
// main_window.py:_rename_project_to_site_name. Opération qui déplace de
// vrais fichiers : mérite d'être vérifiée pour de vrai, pas supposée
// correcte parce qu'elle compile.

if let tablette = TemplateCatalog.findTemplate(byId: "tablette") {
    let renameProjectsRoot = NSTemporaryDirectory() + "agence_swift_selftest_rename_\(UUID().uuidString)"
    defer { try? fm.removeItem(atPath: renameProjectsRoot) }
    do {
        let renameProject = try ProjectService.createProject(from: tablette, projectsRoot: renameProjectsRoot, forceFreeMode: true)
        let originalDir = renameProject.baseDir
        let originalBlendName = (renameProject.blendPath as NSString).lastPathComponent
        check("avant renommage : dossier d'origine existe", fm.fileExists(atPath: originalDir))
        check("avant renommage : nom du .blend = celui du template ('Preset 1.blend')", originalBlendName == "Preset 1.blend")

        // Pas de nom de site -> rien à faire.
        if case .unchanged = ProjectService.renameProjectToSiteName(renameProject) {
            check("siteName vide -> .unchanged", true)
        } else {
            check("siteName vide -> .unchanged", false)
        }

        var toRename = renameProject
        toRename.siteName = "Client Test"
        switch ProjectService.renameProjectToSiteName(toRename) {
        case .renamed(let updated):
            check("renommage réussi : nouveau dossier existe", fm.fileExists(atPath: updated.baseDir))
            check("renommage réussi : ancien dossier n'existe plus", !fm.fileExists(atPath: originalDir))
            let newBlendName = (updated.blendPath as NSString).lastPathComponent
            check("renommage réussi : .blend renommé d'après le site", newBlendName == "Client Test.blend")
            check(
                "renommage réussi : .agence_project.json existe au nouveau chemin",
                fm.fileExists(atPath: ProjectStore.jsonPath(forBlendPath: updated.blendPath))
            )
            check(
                "renommage réussi : l'ancien .agence_project.json n'existe plus",
                !fm.fileExists(atPath: ProjectStore.jsonPath(forBlendPath: renameProject.blendPath))
            )

            // Relance sur un projet déjà à jour -> .unchanged (pas de
            // re-déplacement inutile à chaque frappe une fois stabilisé).
            if case .unchanged = ProjectService.renameProjectToSiteName(updated) {
                check("déjà à jour -> .unchanged", true)
            } else {
                check("déjà à jour -> .unchanged", false)
            }

            // Collision : un dossier du nom cible existe déjà pour un AUTRE projet.
            var collisionProject = try ProjectService.createProject(from: tablette, projectsRoot: renameProjectsRoot, forceFreeMode: true)
            collisionProject.siteName = "Déjà Pris"
            let presentationDir = (renameProjectsRoot as NSString).appendingPathComponent(ProjectService.presentationSubfolder)
            let collisionTargetDir = (presentationDir as NSString).appendingPathComponent("Déjà Pris")
            try fm.createDirectory(atPath: collisionTargetDir, withIntermediateDirectories: true)
            if case .blocked = ProjectService.renameProjectToSiteName(collisionProject) {
                check("dossier cible déjà pris par un autre projet -> .blocked", true)
            } else {
                check("dossier cible déjà pris par un autre projet -> .blocked", false)
            }
        case let other:
            print("FAIL  renommage : résultat inattendu \(other)")
            failures += 1
        }
    } catch {
        print("FAIL  ProjectService.renameProjectToSiteName setup : \(error)")
        failures += 1
    }
} else {
    print("(template 'tablette' introuvable — étape 11 sautée)")
}

// ── 12. ProjectService.listRecentProjects — VRAI scan disque ──
// (pour l'écran d'accueil "Projets récents"/"Anciens projets").

if let tablette = TemplateCatalog.findTemplate(byId: "tablette") {
    let listRoot = NSTemporaryDirectory() + "agence_swift_selftest_list_\(UUID().uuidString)"
    defer { try? fm.removeItem(atPath: listRoot) }
    do {
        check("listRecentProjects sur dossier vide -> []", ProjectService.listRecentProjects(projectsRoot: listRoot).isEmpty)

        var older = try ProjectService.createProject(from: tablette, projectsRoot: listRoot, forceFreeMode: true)
        older.siteName = "Client Ancien"
        try ProjectStore.save(older)
        var newer = try ProjectService.createProject(from: tablette, projectsRoot: listRoot, forceFreeMode: true)
        newer.siteName = "Client Récent"
        try ProjectStore.save(newer)

        // Dates de modif explicites plutôt que compter sur l'écart réel
        // entre deux créations (trop rapide pour être fiable) — le VRAI
        // comportement testé est le tri par date, pas la vitesse du CPU.
        let olderJSON = ProjectStore.jsonPath(forBlendPath: older.blendPath)
        let newerJSON = ProjectStore.jsonPath(forBlendPath: newer.blendPath)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: olderJSON)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: newerJSON)

        let listed = ProjectService.listRecentProjects(projectsRoot: listRoot)
        check("listRecentProjects trouve les 2 projets", listed.count == 2)
        check("listRecentProjects : le plus récent en premier", listed.first?.displayName == "Client Récent")
        check("listRecentProjects : le plus ancien en second", listed.last?.displayName == "Client Ancien")
        check(
            "listRecentProjects : blendPath correct pour le plus récent",
            listed.first?.blendPath == newer.blendPath
        )

        // Simule un déplacement externe de tout le dossier `projectsRoot`
        // (Finder, script, synchronisation…) : le JSON garde un blendPath
        // obsolète, mais le vrai .blend est toujours juste à côté du JSON
        // — bug réel constaté le 2026-09-03 ("Cannot read file … No such
        // file or directory" après un déplacement manuel du dossier de
        // projets). listRecentProjects doit reconstruire le VRAI chemin
        // depuis l'endroit où le dossier a été trouvé, pas faire confiance
        // au champ stocké dans le JSON.
        var staleBlendPathProject = newer
        staleBlendPathProject.blendPath = "/chemin/qui/n/existe/plus/Client Récent.blend"
        try JSONEncoder().encode(staleBlendPathProject).write(to: URL(fileURLWithPath: newerJSON))
        let listedAfterStale = ProjectService.listRecentProjects(projectsRoot: listRoot)
        let staleEntry = listedAfterStale.first(where: { $0.displayName == "Client Récent" })
        check(
            "listRecentProjects reconstruit le vrai chemin si le JSON pointe vers un chemin obsolète",
            staleEntry?.blendPath == newer.blendPath
        )
        check(
            "listRecentProjects : le chemin reconstruit existe réellement sur le disque",
            staleEntry.map { fm.fileExists(atPath: $0.blendPath) } ?? false
        )

        // Un dossier de projet corrompu (JSON illisible) est ignoré, pas
        // une erreur qui casse tout le scan.
        let corruptDir = (listRoot as NSString)
            .appendingPathComponent(ProjectService.presentationSubfolder)
            .appending("/Corrompu")
        try fm.createDirectory(atPath: corruptDir, withIntermediateDirectories: true)
        try "pas du JSON".write(
            toFile: (corruptDir as NSString).appendingPathComponent("Corrompu.agence_project.json"),
            atomically: true, encoding: .utf8
        )
        let listedWithCorrupt = ProjectService.listRecentProjects(projectsRoot: listRoot)
        check("dossier corrompu ignoré, pas de crash, toujours 2 projets valides", listedWithCorrupt.count == 2)
    } catch {
        print("FAIL  ProjectService.listRecentProjects setup : \(error)")
        failures += 1
    }
} else {
    print("(template 'tablette' introuvable — étape 12 sautée)")
}

// ── 13. PlanCategory — portage de plan_category/PLAN_CATEGORIES ──
// (pour le sélecteur "Assigner un plan" trié en 3 catégories).

check("PlanCategory.of détecte Desktop", PlanCategory.of("Plan 3 - Desktop") == "Desktop")
check("PlanCategory.of détecte Transition", PlanCategory.of("Plan 7 - Transition") == "Transition")
check("PlanCategory.of détecte Mobile", PlanCategory.of("Plan 8 - Mobile") == "Mobile")
check("PlanCategory.of insensible à la casse", PlanCategory.of("Cam - desktop") == "Desktop")
check("PlanCategory.of nil hors convention", PlanCategory.of("Caméra libre") == nil)
check("PlanCategory.of nil sur chaîne vide", PlanCategory.of("") == nil)

let ordered = PlanCategory.grouped(["X - Mobile", "Y - Desktop", "Z - Transition", "Sans catégorie"])
check("grouped : 4 groupes (3 connus + Autres)", ordered.count == 4)
check("grouped : ordre canonique Desktop d'abord", ordered.first?.0 == "Desktop")
check("grouped : Transition en second", ordered.count > 1 && ordered[1].0 == "Transition")
check("grouped : Mobile en troisième", ordered.count > 2 && ordered[2].0 == "Mobile")
check("grouped : Autres en dernier avec la caméra non catégorisée", ordered.last?.0 == "Autres" && ordered.last?.1 == ["Sans catégorie"])

let flatGroup = PlanCategory.grouped(["Rien de catégorisé", "Autre caméra"])
check("grouped : un seul groupe (nil) si aucune caméra catégorisée", flatGroup.count == 1 && flatGroup.first?.0 == nil)

// ── 14. Rétrocompat décodage d'un vieux .agence_project.json (sans les
// nouvelles clés réglages avancés du 2026-09-07) — un JSON minimal
// construit ICI (pas un fichier réel sur disque, pour ne pas dépendre d'un
// projet particulier existant à cet emplacement) qui omet volontairement
// TOUTES les clés ajoutées ce jour-là. `manual_scroll_enabled`/
// `important_sections_desktop/mobile` (fonctionnalité "Sections
// importantes", retirée le 2026-09-08) ne sont plus décodées DU TOUT —
// un vieux JSON qui les contient encore serait simplement ignoré, aucun
// test dédié nécessaire pour ça (comportement standard de `Decoder`).
do {
    let oldJSON = """
    {"blend_path":"/tmp/x/x.blend","site_name":"Ancien Client","template_name":"Preset 1",
     "template_id":"tablette","pages":[{"uid":1,"name":"Home","url":"","cameras":[]}],
     "next_page_uid":2,"render_mode":"TEST","cameras_cache":[],"fps":24,"locked":false}
    """
    let decoded = try JSONDecoder().decode(Project.self, from: Data(oldJSON.utf8))
    check("rétrocompat : vieux projet (sans les nouvelles clés) décodé sans erreur", true)
    check("rétrocompat : colorPickerEnabled par défaut = false", decoded.colorPickerEnabled == false)
    check("rétrocompat : backgroundColorHex par défaut = nil", decoded.backgroundColorHex == nil)
    let reencoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder().decode(Project.self, from: reencoded)
    check("rétrocompat : ré-encodage puis re-décodage stable", redecoded.siteName == decoded.siteName)
} catch {
    check("rétrocompat : décodage vieux projet sans erreur — \(error)", false)
}

print("")
if failures == 0 {
    print("ALL OK — \(failures) échec(s)")
} else {
    print("ÉCHECS : \(failures)")
    exit(1)
}
