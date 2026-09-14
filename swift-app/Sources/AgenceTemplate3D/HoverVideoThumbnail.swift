import AVFoundation
import AVKit
import SwiftUI

/// Portage de card_grid.py:HoverVideoLabel (mode standalone) — miniature
/// photo statique, vidéo (muette, en boucle) par-dessus au survol,
/// revient à la photo dès que la souris quitte. Contrairement à Python
/// (qui peint chaque frame à la main sur un QLabel — contournement d'un
/// bug d'affichage propre à QVideoWidget), AVPlayerLayer sur macOS n'a pas
/// ce problème : composant standard.
///
/// NOTE sur la portée : côté Python, `video_path` n'arrive JAMAIS pour un
/// plan déjà assigné à une page (list_shots — voir headless.py:
/// cmd_list_shots — ne renvoie jamais de clé "video", seulement "name"/
/// "thumbnail"/"frames") ; seuls les TEMPLATES (`Template.videoPath`,
/// `templates/manifest.json`) en ont un. Donc cette vue n'est utile QUE
/// pour la grille de sélection de template, pas pour `PlanChipView`.
struct HoverVideoThumbnail: View {
    let thumbnailPath: String?
    let videoPath: String?
    @State private var isHovering = false

    private var hasVideo: Bool {
        guard let videoPath else { return false }
        return FileManager.default.fileExists(atPath: videoPath)
    }

    var body: some View {
        // GeometryReader donne la taille RÉELLEMENT disponible, pixel
        // près — plus fiable que `.aspectRatio(contentMode: .fill)` +
        // `.frame(maxWidth/maxHeight: .infinity)` seul, qui a laissé un
        // liseré de la couleur de fond visible en haut de la miniature
        // malgré ça (constaté par l'utilisateur, premier correctif
        // insuffisant) — `.aspectRatio` remonte sa propre taille "idéale"
        // à son parent pour la négociation de layout, ce qui peut encore
        // décaler le rendu final même avec un `.frame` flexible juste
        // après. Ici, la taille cible est lue explicitement PUIS imposée
        // au pixel, sans laisser SwiftUI négocier.
        GeometryReader { geo in
            ZStack {
                if isHovering, hasVideo, let videoPath {
                    LoopingVideoPlayerView(url: URL(fileURLWithPath: videoPath))
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let thumbnailPath, let nsImage = NSImage(contentsOfFile: thumbnailPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    // Fond noir uni (pas de "?") quand ni photo ni vidéo
                    // ne sont disponibles — demandé explicitement le
                    // 2026-09-02.
                    Color.black
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .onHover { hovering in
            isHovering = hovering && hasVideo
        }
    }
}

/// AVQueuePlayer + AVPlayerLooper : boucle infinie fiable (contrairement à
/// observer manuellement AVPlayerItemDidPlayToEndTime + seek). Muet —
/// aperçu silencieux, jamais de son surprise (même choix que Python).
private struct LoopingVideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        context.coordinator.player = queuePlayer
        view.playerLayer.player = queuePlayer
        queuePlayer.play()
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        // Gardés en vie tant que la vue existe — un AVPlayerLooper non
        // retenu ailleurs s'arrête tout seul.
        var looper: AVPlayerLooper?
        var player: AVQueuePlayer?
    }
}

private final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non utilisé")
    }
}
