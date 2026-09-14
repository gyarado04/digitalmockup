import AgenceTemplate3DCore
import Foundation

/// Diagnostic interne baké dans l'app SHIPPÉE — même principe que
/// `AGENCE_SELFTEST=video` côté Python (app/main.py) : quand la variable
/// d'environnement est posée, l'app saute son UI normale, fait un vrai
/// contrôle, imprime PASS/FAIL sur stdout, puis quitte. Utile pour
/// vérifier un `.app` empaqueté PRÉCIS (pas juste `swift run` en dev) sans
/// avoir à cliquer dedans — notamment que
/// `TemplateCatalog`/`BlenderBridge` trouvent bien leurs ressources
/// bundlées (`Contents/Resources/`) plutôt que de dépendre par accident de
/// l'arbre source du projet (voir leurs commentaires "bundled vs dev").
///
/// `AGENCE_SELFTEST=blender` : liste les templates, vérifie que
/// headless.py est résolu et existe, fait un VRAI appel Blender
/// (list_shots sur le template "tablette").
///
/// `AGENCE_SELFTEST=capture` (`AGENCE_SELFTEST_CAPTURE_URL` = l'URL à
/// capturer) : fait une VRAIE capture web (WebCapture, avec sa fenêtre
/// hôte — voir son commentaire "useHostWindow") et écrit le résultat dans
/// `<tmp>/agence_selftest_capture.png`. Contrairement à
/// AgenceTemplate3DSelfTest (l'outil CLI, sans vraie boucle NSApplication,
/// où créer cette fenêtre hôte bloque indéfiniment), l'app réelle EST le
/// bon contexte pour ce test. Planifié via `DispatchQueue.main.async`
/// (pas synchrone comme "blender" ci-dessus) : à l'instant où
/// `runIfRequested()` tourne (dans `init()` de l'App SwiftUI),
/// `NSApplication.run()` n'a pas encore démarré sa vraie boucle —
/// repousser au tour de boucle suivant laisse la vraie boucle s'installer
/// avant de créer une fenêtre.
enum SelfTestRunner {
    static func runIfRequested() {
        if ProcessInfo.processInfo.environment["AGENCE_SELFTEST"] == "capture" {
            let urlString = ProcessInfo.processInfo.environment["AGENCE_SELFTEST_CAPTURE_URL"] ?? "https://example.com"
            let outPath = NSTemporaryDirectory() + "agence_selftest_capture.png"
            DispatchQueue.main.async {
                Task { @MainActor in
                    do {
                        try await WebCapture().capture(
                            url: URL(string: urlString)!, viewportWidth: 1920, viewportHeight: 1080, outputPath: outPath
                        )
                        print("AGENCE_SELFTEST capture_ok path=\(outPath)")
                        print("AGENCE_SELFTEST", "PASS")
                        exit(0)
                    } catch {
                        print("AGENCE_SELFTEST FAIL: \(error)")
                        print("AGENCE_SELFTEST", "FAIL")
                        exit(1)
                    }
                }
            }
            return
        }

        guard ProcessInfo.processInfo.environment["AGENCE_SELFTEST"] == "blender" else { return }
        var ok = true

        let templatesRoot = TemplateCatalog.templatesRoot()
        let templates = TemplateCatalog.listTemplates()
        print("AGENCE_SELFTEST templates_root=\(templatesRoot)")
        print("AGENCE_SELFTEST templates_count=\(templates.count)")
        if templates.isEmpty {
            print("AGENCE_SELFTEST FAIL: aucun template trouvé")
            ok = false
        }

        guard let tablette = templates.first(where: { $0.id == "tablette" }) else {
            print("AGENCE_SELFTEST FAIL: template 'tablette' introuvable")
            print("AGENCE_SELFTEST", "FAIL")
            exit(1)
        }

        let scriptPath = BlenderBridge.headlessScriptPath()
        let scriptExists = FileManager.default.fileExists(atPath: scriptPath)
        print("AGENCE_SELFTEST headless_script=\(scriptPath) exists=\(scriptExists)")
        if !scriptExists {
            print("AGENCE_SELFTEST", "FAIL")
            exit(1)
        }

        do {
            // cache_dir requis : headless.py:cmd_list_shots renvoie
            // volontairement shots=[] (ok=true quand même) sans lui, pour
            // pouvoir écrire les miniatures des caméras.
            let cacheDir = NSTemporaryDirectory() + "agence_selftest_blender_cache_" + UUID().uuidString
            let result = try BlenderBridge.runHeadless(
                blendPath: tablette.blendPath, command: "list_shots", config: ["cache_dir": cacheDir]
            )
            let shots = (result["shots"] as? [[String: Any]])?.count ?? 0
            print("AGENCE_SELFTEST list_shots_ok shots=\(shots)")
            if shots == 0 { ok = false }
        } catch {
            print("AGENCE_SELFTEST FAIL: appel Blender : \(error)")
            print("AGENCE_SELFTEST", "FAIL")
            exit(1)
        }

        print("AGENCE_SELFTEST", ok ? "PASS" : "FAIL")
        exit(ok ? 0 : 1)
    }
}
