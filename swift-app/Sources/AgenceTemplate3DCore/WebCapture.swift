import AppKit
import Foundation
import WebKit

/// Capture web (desktop + mobile) — portage NATIF de app/core/capture.py
/// (qui utilisait Playwright/Chromium en sous-process Python) : WKWebView +
/// takeSnapshot, aucune dépendance externe à télécharger. Décidé avec
/// l'utilisateur le 2026-09-01.
///
/// Scroll progressif pour déclencher les animations au scroll (AOS,
/// ScrollTrigger…), retour en haut, puis capture par TRANCHES à la vraie
/// taille de viewport recollées en une image pleine page (voir
/// `captureStitched`) — PAS un simple resize-puis-snapshot (essayé
/// d'abord, comme capture.py/Playwright, mais cassait les animations
/// d'apparition au scroll : "il n'y a pas les animations d'apparition",
/// 2026-09-08, voir le commentaire de `captureStitched`).
///
/// WKWebView est une vue AppKit : doit être piloté sur le thread principal
/// (@MainActor). N'utilise AUCUNE macro SwiftUI — pur AppKit/WebKit/
/// Foundation, donc compile sans Xcode (contrairement au reste de l'UI,
/// voir README "Prérequis machine").
public enum WebCaptureError: Error, CustomStringConvertible {
    case loadFailed(String)
    case snapshotFailed(String)

    public var description: String {
        switch self {
        case .loadFailed(let message): return "Chargement de la page impossible : \(message)"
        case .snapshotFailed(let message): return "Capture d'écran impossible : \(message)"
        }
    }
}

@MainActor
public final class WebCapture: NSObject, WKNavigationDelegate {
    // Mêmes réglages que app/core/capture.py (SCROLL_STEP_PX, etc.)
    public static let scrollStepPx = 300
    public static let scrollDelayNs: UInt64 = 400_000_000
    public static let finalWaitNs: UInt64 = 1_500_000_000
    /// Attente après avoir scrollé à chaque tranche de la capture finale
    /// (voir `captureStitched`) — le temps qu'une transition CSS/JS
    /// d'apparition (souvent 300 à 1000ms selon le site) ait fini de jouer
    /// avant de prendre le snapshot de cette tranche.
    public static let sliceSettleNs: UInt64 = 700_000_000
    /// Images par seconde de la séquence enregistrée par
    /// `captureFrameSequence` — un compromis entre fluidité et nombre
    /// d'appels `takeSnapshot` (chacun coûte du temps réel, puisqu'on
    /// enregistre le scroll en TEMPS RÉEL).
    ///
    /// 8fps essayé d'abord, jugé "super saccadé" par l'utilisateur sur un
    /// vrai rendu (2026-09-08) : le rendu final tourne à 24fps
    /// (`headless.py:SEQUENCE_CAPTURE_FPS`, MÊME VALEUR, à garder en sync
    /// — comme `DESKTOP_WIDTH`/`MOBILE_WIDTH`), donc à 8fps chaque frame
    /// capturée restait affichée ~3 frames de rendu d'affilée (24/8), un
    /// mouvement de scroll par à-coups bien visible. 24fps = une frame
    /// capturée par frame de rendu, plus de palier.
    public static let videoFps: Int32 = 24

    private var loadContinuation: CheckedContinuation<Void, Error>?

    public override init() {
        super.init()
    }

    /// Prépare une `WKWebView` (+ fenêtre hôte optionnelle, voir
    /// `useHostWindow` sur `capture`) sur la page demandée : charge l'URL,
    /// attend le réseau calme + le chargement des `<video>` — factorise le
    /// préambule commun à `capture` (image) et `captureFrameSequence`
    /// (séquence d'images, 2026-09-08). En cas d'échec de chargement, nettoie la fenêtre hôte
    /// AVANT de relancer l'erreur (sinon elle resterait orpheline : la
    /// fenêtre n'est jamais renvoyée à l'appelant sur ce chemin d'échec).
    private static func makeAndLoadWebView(
        navigationDelegate: WKNavigationDelegate,
        loadContinuation setLoadContinuation: (CheckedContinuation<Void, Error>) -> Void,
        url: URL, viewportWidth: Int, viewportHeight: Int, useHostWindow: Bool
    ) async throws -> (WKWebView, NSWindow?) {
        let configuration = WKWebViewConfiguration()
        // Autorise la lecture automatique (muette) des <video> — sans
        // cette ligne, le comportement d'autoplay par défaut de WKWebView
        // n'est pas garanti identique à Safari/Chrome.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight), configuration: configuration)
        webView.navigationDelegate = navigationDelegate

        // Fenêtre hôte quasi invisible (alpha ~0, jamais montrée à
        // l'utilisateur) — nécessaire pour qu'une `<video>` de la page
        // (fond "hero" animé, très courant) charge réellement ses données ;
        // sans fenêtre, elle reste bloquée à `readyState 0, currentSrc: ""`
        // (bug signalé le 2026-09-03). `alphaValue` proche de 0 (pas
        // exactement 0) + `orderFront` : reste "visible" pour WindowServer
        // (pas occultée), donc WebKit ne met pas son rendu en veille, sans
        // jamais rien afficher à l'écran. Seul inconvénient connu : créer
        // une VRAIE fenêtre ne fonctionne QUE dans un process avec une
        // vraie boucle `NSApplication` qui tourne (l'app réelle,
        // packagée) — bloque indéfiniment dans un simple exécutable CLI
        // sans cette boucle (voir `false` utilisé par le self-test local,
        // qui n'a pas de vidéo à charger de toute façon).
        var hostWindow: NSWindow?
        if useHostWindow {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.alphaValue = 0.001
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.contentView = webView
            window.orderFront(nil)
            hostWindow = window
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                setLoadContinuation(continuation)
                webView.load(URLRequest(url: url))
            }

            // Laisse le layout initial se stabiliser.
            try await Task.sleep(nanoseconds: 500_000_000)

            // Portage manquant de `page.goto(url, wait_until="networkidle")`
            // côté Python (Playwright) : `didFinish navigation` ne signale
            // que le DOCUMENT principal chargé, PAS les requêtes
            // asynchrones lancées ensuite (images, polices, appels JS/ajax
            // — très courant sur un site WordPress) — contrairement à
            // Playwright, qui attendait explicitement que le réseau se
            // calme avant de continuer.
            await Self.waitForNetworkIdle(webView)
            // Force la mise en tampon des `<video>` de la page — sans
            // appel explicite à `.play()`, WKWebView ne garantit pas de
            // commencer à charger une vidéo juste parce qu'elle a
            // l'attribut `autoplay` (contrairement à ce que ferait un vrai
            // navigateur pour l'utilisateur). `.catch(() => {})` : ignore
            // un rejet de promesse (rare avec muted+autorisé ci-dessus,
            // mais sans conséquence pour la capture même si ça arrivait).
            _ = try? await webView.evaluateJavaScript(
                "document.querySelectorAll('video').forEach(v => { v.muted = true; v.play().catch(() => {}); })"
            )
            await Self.waitForVideosToLoad(webView)
        } catch {
            hostWindow?.orderOut(nil)
            hostWindow?.contentView = nil
            throw error
        }

        return (webView, hostWindow)
    }

    /// Capture pleine page à ce viewport, écrit un PNG à outputPath — même
    /// séquence que _scroll_then_capture côté Python.
    ///
    /// `useHostWindow` (true par défaut) : attache la WKWebView à une VRAIE
    /// fenêtre (quasi invisible) pendant la capture — nécessaire pour
    /// qu'une `<video>` de la page (fond "hero" animé, très courant) charge
    /// réellement ses données ; sans fenêtre, elle reste bloquée à
    /// `readyState 0, currentSrc: ""` (bug signalé le 2026-09-03 : "les
    /// images ne sont pas pris dans la capture" — la "photo" en cause
    /// était en fait une vidéo). Seul inconvénient connu : créer une VRAIE
    /// fenêtre ne fonctionne QUE dans un process avec une vraie boucle
    /// `NSApplication` qui tourne (l'app réelle, packagée) — bloque
    /// indéfiniment dans un simple exécutable CLI sans cette boucle (voir
    /// `false` utilisé par le self-test local, qui n'a pas de vidéo à
    /// charger de toute façon).
    public func capture(
        url: URL, viewportWidth: Int, viewportHeight: Int, outputPath: String, useHostWindow: Bool = true
    ) async throws {
        let (webView, hostWindow) = try await Self.makeAndLoadWebView(
            navigationDelegate: self, loadContinuation: { self.loadContinuation = $0 },
            url: url, viewportWidth: viewportWidth, viewportHeight: viewportHeight, useHostWindow: useHostWindow
        )
        defer {
            hostWindow?.orderOut(nil)
            hostWindow?.contentView = nil
        }

        var guardCount = 0
        while guardCount < 2000 {
            let state = try? await webView.evaluateJavaScript(
                "({scrollY: window.scrollY, viewportHeight: window.innerHeight, fullHeight: document.body.scrollHeight})"
            ) as? [String: Any]
            let scrollY = (state?["scrollY"] as? NSNumber)?.doubleValue ?? 0
            let vh = (state?["viewportHeight"] as? NSNumber)?.doubleValue ?? Double(viewportHeight)
            let fullHeight = (state?["fullHeight"] as? NSNumber)?.doubleValue ?? vh
            if scrollY + vh >= fullHeight - 2 { break }
            _ = try? await webView.evaluateJavaScript("window.scrollBy(0, \(Self.scrollStepPx))")
            try await Task.sleep(nanoseconds: Self.scrollDelayNs)
            guardCount += 1
        }

        try await Task.sleep(nanoseconds: Self.finalWaitNs)

        // Retour en haut avant la capture définitive.
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0)")
        let fullHeightValue = try? await webView.evaluateJavaScript("document.body.scrollHeight") as? NSNumber
        let fullHeight = fullHeightValue?.intValue ?? viewportHeight

        // IMPORTANT : on NE redimensionne PLUS la WKWebView à la hauteur
        // complète de la page avant de capturer (contrairement à avant,
        // qui faisait `webView.frame = ...hauteur complète...` puis UN
        // SEUL snapshot). Bug signalé le 2026-09-08 : "il n'y a pas les
        // animations d'apparition" — cause : la plupart des bibliothèques
        // d'animation au scroll (AOS, ScrollReveal, GSAP ScrollTrigger,
        // interactions Webflow…) calculent leurs seuils de déclenchement à
        // partir de `window.innerHeight`, et une fois la fenêtre aussi
        // haute que la page entière, `document.scrollHeight ==
        // window.innerHeight` : il n'y a plus AUCUN scroll possible
        // (`scrollY` reste bloqué à 0), donc plus rien ne se déclenche (ou
        // se réinitialise sans jamais se redéclencher, selon la
        // bibliothèque). Remplacé par `captureStitched` : capture la page
        // par tranches, À LA VRAIE TAILLE DE VIEWPORT (celle qu'un vrai
        // visiteur aurait), en scrollant comme un utilisateur normal, puis
        // recolle les tranches en une seule image pleine page — approche
        // générique qui ne dépend d'aucune connaissance de la bibliothèque
        // d'animation utilisée par tel ou tel site client.
        let image = try await Self.captureStitched(
            webView, viewportWidth: viewportWidth, viewportHeight: viewportHeight, fullHeight: fullHeight
        )

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw WebCaptureError.snapshotFailed("conversion PNG impossible")
        }
        try pngData.write(to: URL(fileURLWithPath: outputPath))
    }

    /// Enregistre un scroll RÉEL de la page (comme un vrai visiteur), à la
    /// vraie taille de viewport, en SÉQUENCE D'IMAGES NUMÉROTÉES — pour
    /// préserver le MOUVEMENT des animations d'apparition au scroll, pas
    /// seulement leur état final (`capture`, l'image fixe, ne peut PAS
    /// montrer un mouvement : une image ne contient qu'un seul instant,
    /// voir son commentaire). Chaque frame est capturée avec
    /// `takeSnapshot` (même mécanisme que `capture`) puis écrite comme
    /// `frame_0001.png`, `frame_0002.png`, … dans `outputDir` — Blender
    /// sait nativement jouer ce genre de séquence comme texture animée
    /// (`Image.source = 'SEQUENCE'`), aucune dépendance d'encodage vidéo
    /// à ajouter. 2026-09-08, demande explicite après le correctif de
    /// `capture` : "je parlais des animations d'apparition des éléments
    /// (...) elle apparaissent avec l'animation finie mais pas avec
    /// l'apparition de l'animation" — d'abord essayé en vidéo
    /// (AVFoundation), mais la vérification en conditions réelles
    /// (fenêtre hôte + vraie boucle NSApplication) s'est heurtée à un
    /// blocage de lancement de l'app dans cet environnement d'outillage
    /// (pas une preuve que la vidéo ne marcherait pas, juste un obstacle
    /// abandonné) — reparti sur cette approche plus simple à la place.
    ///
    /// Côté Blender, cette séquence remplace l'image statique comme
    /// texture de l'écran : au lieu de faire défiler (Mapping node) une
    /// image géante, Blender AFFICHE LA BONNE FRAME de cette séquence
    /// selon la progression du scroll (`image_user.frame_start`/
    /// `frame_offset`, voir `headless.py`) — chaque frame est déjà le bon
    /// cadrage, capturé au bon instant du vrai scroll, donc plus besoin du
    /// Mapping node pour "simuler" un défilement.
    ///
    /// Retourne le nombre de frames écrites (>= 1) — nécessaire côté
    /// Blender pour régler `image_user.frame_duration`/borner la
    /// recherche de frame.
    ///
    /// `onProgress` (optionnel) : rappelé avec la fraction de scroll
    /// complétée (0.0→1.0, PAS un nombre de frames — inconnu à l'avance,
    /// dépend de la vraie hauteur de la page une fois chargée) après
    /// chaque frame écrite — cette capture prenant maintenant le temps
    /// d'un vrai scroll (~10-60s selon la page, 2026-09-08), une barre de
    /// progression déterminée est nécessaire côté UI plutôt qu'un simple
    /// spinner indéterminé (demande explicite de l'utilisateur).
    @discardableResult
    public func captureFrameSequence(
        url: URL, viewportWidth: Int, viewportHeight: Int, outputDir: String, useHostWindow: Bool = true,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Int {
        let (webView, hostWindow) = try await Self.makeAndLoadWebView(
            navigationDelegate: self, loadContinuation: { self.loadContinuation = $0 },
            url: url, viewportWidth: viewportWidth, viewportHeight: viewportHeight, useHostWindow: useHostWindow
        )
        defer {
            hostWindow?.orderOut(nil)
            hostWindow?.contentView = nil
        }

        try? FileManager.default.removeItem(atPath: outputDir)
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = webView.bounds

        var frameIndex = 0
        @discardableResult
        func saveFrame() async throws -> Int {
            let nsImage: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: snapshotConfig) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: WebCaptureError.snapshotFailed(error?.localizedDescription ?? "erreur inconnue"))
                    }
                }
            }
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw WebCaptureError.snapshotFailed("conversion d'une frame de la séquence impossible")
            }
            frameIndex += 1
            // Numérotation sur 4 chiffres — Blender (source='SEQUENCE')
            // détecte le motif numérique dans le nom de fichier lui-même,
            // peu importe le nombre de chiffres, mais un format fixe évite
            // tout tri lexicographique fantaisiste (frame_10 avant
            // frame_2) si jamais un outil externe liste ce dossier.
            let path = (outputDir as NSString).appendingPathComponent(String(format: "frame_%04d.png", frameIndex))
            try pngData.write(to: URL(fileURLWithPath: path))
            return frameIndex
        }

        // Première frame (haut de page, avant tout scroll).
        try await saveFrame()
        onProgress?(0.0)

        // Vitesse de scroll réel — même repère visuel que
        // headless.py:SECONDS_PER_VIEWPORT_HEIGHT (4 secondes pour défiler
        // une hauteur d'écran) : garde un rythme cohérent avec ce
        // qu'affichait déjà l'app pour une capture image (scroll_fraction),
        // plutôt qu'une vitesse arbitraire nouvelle.
        let pxPerSecond = Double(viewportHeight) / 4.0
        let pxPerFrame = max(1.0, pxPerSecond / Double(Self.videoFps))

        var guardCount = 0
        while guardCount < 4000 {
            let state = try? await webView.evaluateJavaScript(
                "({scrollY: window.scrollY, viewportHeight: window.innerHeight, fullHeight: document.body.scrollHeight})"
            ) as? [String: Any]
            let scrollY = (state?["scrollY"] as? NSNumber)?.doubleValue ?? 0
            let vh = (state?["viewportHeight"] as? NSNumber)?.doubleValue ?? Double(viewportHeight)
            let fullHeight = (state?["fullHeight"] as? NSNumber)?.doubleValue ?? vh
            if scrollY + vh >= fullHeight - 2 { break }
            _ = try? await webView.evaluateJavaScript("window.scrollBy(0, \(pxPerFrame))")
            try await Task.sleep(nanoseconds: UInt64(1_000_000_000.0 / Double(Self.videoFps)))
            try await saveFrame()
            // `(scrollY + vh) / fullHeight` : fraction de la page déjà
            // visible en bas d'écran après ce scroll — atteint 1.0 pile
            // quand la boucle est sur le point de s'arrêter (condition
            // `break` ci-dessus), donc jamais bloquée sous 100% à tort.
            if fullHeight > 0 { onProgress?(min(1.0, (scrollY + pxPerFrame + vh) / fullHeight)) }
            guardCount += 1
        }

        // Dernière frame garantie tout en bas (le dernier pas de scroll ne
        // colle pas forcément exactement au bas de la page) — laisse le
        // temps à une éventuelle animation encore en cours de finir.
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
        try await Task.sleep(nanoseconds: Self.sliceSettleNs)
        try await saveFrame()
        onProgress?(1.0)

        // Sidecar JSON : à QUEL RYTHME cette séquence précise a été
        // capturée — bug corrigé le 2026-09-08 ("la vidéo est en
        // accéléré") : `headless.py` interprétait le nombre de frames
        // d'une séquence en durée réelle via une CONSTANTE GLOBALE
        // (`SEQUENCE_CAPTURE_FPS`) — en la faisant passer de 8 à 24fps
        // (pour corriger un souci de saccades), les séquences DÉJÀ
        // capturées à 8fps se sont retrouvées rejouées 3x trop vite
        // (mauvais rythme reconstitué). Ce fichier fige, PAR SÉQUENCE, le
        // fps réellement utilisé à SA capture — `headless.py` le lit en
        // priorité, la constante globale ne sert plus que de repli pour
        // une séquence capturée avant l'ajout de ce fichier.
        let metaPath = (outputDir as NSString).appendingPathComponent("sequence_meta.json")
        if let metaData = try? JSONSerialization.data(withJSONObject: ["fps": Self.videoFps]) {
            try? metaData.write(to: URL(fileURLWithPath: metaPath))
        }

        return frameIndex
    }

    /// Approximation du `wait_until="networkidle"` de Playwright (aucun
    /// équivalent natif côté WKWebView) : sondage de la Resource Timing API
    /// — considéré "calme" dès que le nombre de requêtes réseau observées
    /// n'a plus bougé pendant `quietNs` d'affilée. Se contente d'un
    /// abandon silencieux au bout de `timeoutNs` (un site avec du trafic
    /// permanent — analytics, chat, polling — ne se calmerait jamais sinon)
    /// plutôt que de bloquer la capture indéfiniment.
    private static func waitForNetworkIdle(
        _ webView: WKWebView, timeoutNs: UInt64 = 8_000_000_000, quietNs: UInt64 = 500_000_000
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        var lastCount = -1
        var stableSinceNs = start
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNs {
            let count = (try? await webView.evaluateJavaScript(
                "performance.getEntriesByType('resource').length"
            ) as? NSNumber)?.intValue ?? lastCount
            let now = DispatchTime.now().uptimeNanoseconds
            if count == lastCount {
                if now - stableSinceNs >= quietNs { return }
            } else {
                lastCount = count
                stableSinceNs = now
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Complète `waitForNetworkIdle` : le réseau peut être calme alors
    /// qu'une image reçue est encore en train de DÉCODER côté navigateur
    /// (surtout une grande photo) — attend explicitement que chaque <img>
    /// du DOM soit `.complete`. Mêmes garde-fous qu'au-dessus (abandon
    /// silencieux au bout de `timeoutNs`).
    private static func waitForImagesToLoad(_ webView: WKWebView, timeoutNs: UInt64 = 5_000_000_000) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNs {
            let allLoaded = (try? await webView.evaluateJavaScript(
                "Array.from(document.images).every(img => img.complete)"
            ) as? Bool) ?? true
            if allLoaded { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Une `<video>` (fond animé "hero", très courant) affiche sa frame
    /// courante dès que `readyState >= 2` (`HAVE_CURRENT_DATA`), qu'elle
    /// soit effectivement EN LECTURE ou non — pas besoin d'attendre qu'elle
    /// joue, juste qu'elle ait chargé assez pour avoir une image à montrer.
    /// `document.images` (voir `waitForImagesToLoad`) ne contient PAS les
    /// éléments `<video>` — sans cette vérification séparée, une vidéo
    /// encore à `readyState 0` capture comme une zone vide/transparente.
    private static func waitForVideosToLoad(_ webView: WKWebView, timeoutNs: UInt64 = 5_000_000_000) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNs {
            let allLoaded = (try? await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('video')).every(v => v.readyState >= 2)"
            ) as? Bool) ?? true
            if allLoaded { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Capture la page par tranches de hauteur `viewportHeight` (jamais en
    /// redimensionnant la WKWebView — voir le commentaire au point
    /// d'appel dans `capture`) et les recolle en une seule image pleine
    /// page. Chaque tranche est capturée à la VRAIE taille de viewport, en
    /// scrollant réellement (`window.scrollTo`) comme le ferait un
    /// visiteur — ce qui laisse les animations d'apparition au scroll se
    /// déclencher normalement, quelle que soit la bibliothèque utilisée
    /// par le site (2026-09-08, remplace l'ancien "resize + 1 seul
    /// snapshot").
    private static func captureStitched(
        _ webView: WKWebView, viewportWidth: Int, viewportHeight: Int, fullHeight: Int
    ) async throws -> NSImage {
        let effectiveFullHeight = max(fullHeight, viewportHeight)
        let sliceCount = Int((Double(effectiveFullHeight) / Double(viewportHeight)).rounded(.up))

        // Éléments `position: fixed`/`sticky` (barre de nav, bouton
        // flottant, bandeau cookies…) : repérés UNE SEULE FOIS ici, puis
        // masqués pendant toutes les tranches SAUF la première (celle à
        // scrollY=0, leur position d'affichage naturelle) — sans ça, ils
        // apparaîtraient dupliqués à chaque tranche de l'image recollée
        // (un élément `fixed` reste à la même position d'écran à chaque
        // snapshot, quel que soit le scroll).
        _ = try? await webView.evaluateJavaScript("""
            window.__captureFixedEls = Array.from(document.querySelectorAll('*')).filter(function(el) {
                var cs = getComputedStyle(el);
                return cs.position === 'fixed' || cs.position === 'sticky';
            });
            window.__captureFixedElsOriginalVisibility = window.__captureFixedEls.map(function(el) {
                return el.style.visibility;
            });
            null;
            """)

        var slices: [(cgImage: CGImage, targetYPoints: Int)] = []
        for index in 0..<sliceCount {
            // Dernière tranche : on colle au bas EXACT de la page plutôt
            // que de continuer sur `index * viewportHeight` (qui
            // dépasserait `fullHeight` si ce n'est pas un multiple exact
            // de la hauteur de viewport) — les tranches se chevauchent
            // légèrement à la fin plutôt que de laisser un vide.
            let targetY = index == sliceCount - 1
                ? max(0, effectiveFullHeight - viewportHeight)
                : index * viewportHeight

            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(targetY))")

            if index > 0 {
                _ = try? await webView.evaluateJavaScript(
                    "(window.__captureFixedEls || []).forEach(function(el) { el.style.visibility = 'hidden'; });"
                )
            }

            // Laisse le temps à une transition CSS/JS d'apparition de
            // finir de jouer avant de figer cette tranche, puis re-vérifie
            // images/vidéos (le scroll peut déclencher du lazy-loading).
            try await Task.sleep(nanoseconds: Self.sliceSettleNs)
            await Self.waitForImagesToLoad(webView, timeoutNs: 2_000_000_000)
            await Self.waitForVideosToLoad(webView, timeoutNs: 2_000_000_000)

            let snapshotConfig = WKSnapshotConfiguration()
            snapshotConfig.rect = webView.bounds
            let sliceImage: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: snapshotConfig) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: WebCaptureError.snapshotFailed(error?.localizedDescription ?? "erreur inconnue"))
                    }
                }
            }

            if index > 0 {
                _ = try? await webView.evaluateJavaScript("""
                    (window.__captureFixedEls || []).forEach(function(el, i) {
                        el.style.visibility = (window.__captureFixedElsOriginalVisibility || [])[i] || '';
                    });
                    """)
            }

            var proposedRect = CGRect(x: 0, y: 0, width: sliceImage.size.width, height: sliceImage.size.height)
            guard let cgImage = sliceImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                throw WebCaptureError.snapshotFailed("conversion d'une tranche impossible")
            }
            slices.append((cgImage, targetY))
        }

        guard let firstSlice = slices.first else {
            throw WebCaptureError.snapshotFailed("aucune tranche capturée")
        }

        // Échelle réelle (Retina 2x sur cette machine, voir la correction
        // du noeud Mapping côté headless.py:update_mapping_scale_for_full_page
        // pour le même sujet) déduite de la tranche elle-même plutôt que
        // supposée fixe.
        let pixelScale = CGFloat(firstSlice.cgImage.width) / CGFloat(viewportWidth)
        let widthPx = firstSlice.cgImage.width
        let totalHeightPx = max(1, Int((CGFloat(effectiveFullHeight) * pixelScale).rounded()))

        guard let context = CGContext(
            data: nil, width: widthPx, height: totalHeightPx, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WebCaptureError.snapshotFailed("contexte de composition impossible")
        }

        // `CGContext` a son origine en BAS à gauche, l'axe Y croissant
        // vers le HAUT — contrairement à `targetYPoints` (mesuré depuis le
        // HAUT de la page, comme `window.scrollY`) : on inverse pour
        // chaque tranche. Les tranches sont dessinées dans l'ORDRE (du
        // haut vers le bas), donc la dernière (qui peut chevaucher
        // légèrement la précédente, voir plus haut) est dessinée EN
        // DERNIER et l'emporte sur la zone de chevauchement.
        for slice in slices {
            let sliceHeightPx = slice.cgImage.height
            let targetYPx = CGFloat(slice.targetYPoints) * pixelScale
            let flippedY = CGFloat(totalHeightPx) - targetYPx - CGFloat(sliceHeightPx)
            context.draw(slice.cgImage, in: CGRect(x: 0, y: flippedY, width: CGFloat(widthPx), height: CGFloat(sliceHeightPx)))
        }

        guard let finalCGImage = context.makeImage() else {
            throw WebCaptureError.snapshotFailed("assemblage de l'image finale impossible")
        }
        // Taille LOGIQUE (points/CSS px, ex. viewportWidth=400), PAS la
        // taille en pixels réels (`widthPx`/`totalHeightPx`, ex. 800 en
        // Retina 2x) — `NSImage(cgImage:size:)` prend cette valeur telle
        // quelle (contrairement à `takeSnapshot`, qui renvoyait déjà une
        // NSImage à l'échelle logique) ; sans cette conversion, `.size`
        // rapporte le double de la largeur/hauteur attendue par tout code
        // Swift qui lit ce fichier ensuite — mieux vaut rester cohérent
        // avec le comportement d'avant. Les PIXELS RÉELS écrits dans le PNG final
        // (ce que lit `headless.py` via PIL pour détecter l'échelle Retina,
        // voir `update_mapping_scale_for_full_page`) restent inchangés :
        // ils viennent de `finalCGImage`, pas de cette taille logique.
        return NSImage(cgImage: finalCGImage, size: NSSize(width: viewportWidth, height: effectiveFullHeight))
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: WebCaptureError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: WebCaptureError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }
}
