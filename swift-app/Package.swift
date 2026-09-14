// swift-tools-version: 6.0
// Portage Swift/SwiftUI de l'app — voir README.md dans ce dossier pour l'état
// d'avancement. Package SwiftPM (pas de .xcodeproj) : Xcode n'est pas encore
// installé sur cette machine (seulement les Command Line Tools), mais
// `swift build`/`swift run` fonctionnent déjà avec le toolchain système —
// permet d'avancer (écrire + compiler + vérifier) avant d'installer Xcode.
// Le Package.swift s'ouvre normalement dans Xcode une fois installé (File >
// Open… sur ce fichier), pas besoin de le convertir.
//
// Pas de cible `.testTarget` (XCTest / le nouveau paquet Testing) : leurs
// bibliothèques runtime (XCTest.framework / Testing.framework) ne sont
// fournies que par Xcode, absentes des Command Line Tools seules — testé et
// confirmé (dlopen échoue). À la place : AgenceTemplate3DSelfTest, un
// exécutable CLI ordinaire qui vérifie le code du paquet Core "à la main"
// (assertions + PASS/FAIL sur stdout) — même principe que AGENCE_SELFTEST
// côté app Python. Remplaçable par de vraies cibles de test une fois Xcode
// installé.
//
// macOS le plus récent uniquement (décision explicite de l'utilisateur,
// 2026-09-01) — .v14 est la version la plus haute que connaisse ce
// toolchain pour l'énumération SwiftPM ; le résultat compilé tourne bien
// sur macOS 27 (la vraie machine de dev), .v14 sert juste de plancher
// minimum côté build.

import PackageDescription

let package = Package(
    name: "AgenceTemplate3D",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AgenceTemplate3DCore",
            path: "Sources/AgenceTemplate3DCore"
        ),
        .executableTarget(
            name: "AgenceTemplate3D",
            dependencies: ["AgenceTemplate3DCore"],
            path: "Sources/AgenceTemplate3D",
            // Police Monument Grotesk (design fourni par l'utilisateur,
            // 2026-09-02) — embarquée et enregistrée au lancement
            // (Theme.swift) plutôt que d'exiger qu'elle soit installée sur
            // le système de l'utilisateur final.
            //
            // onboarding_video.mp4 : vidéo de présentation montrée à
            // l'ouverture + rejouable depuis Paramètres (voir
            // OnboardingVideoSheet.swift, 2026-09-08). PLACEHOLDER pour
            // l'instant (fond uni, aucun son, généré par ffmpeg) —
            // l'utilisateur fournira la vraie vidéo plus tard ; il
            // suffira de REMPLACER ce fichier (même nom, même dossier),
            // aucun changement de code nécessaire.
            resources: [
                .copy("Resources/MonumentGrotesk-Regular.otf"),
                .copy("Resources/onboarding_video.mp4"),
            ]
        ),
        .executableTarget(
            name: "AgenceTemplate3DSelfTest",
            dependencies: ["AgenceTemplate3DCore"],
            path: "Sources/AgenceTemplate3DSelfTest"
        ),
    ]
)
