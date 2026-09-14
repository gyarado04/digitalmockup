import AppKit
import SwiftUI

/// Remplace `ColorPicker` — pas utilisable ici : au premier clic, SwiftUI
/// affiche son PROPRE popover (grille de couleurs récentes/système), et ne
/// bascule sur le vrai `NSColorPanel` partagé qu'après un clic
/// supplémentaire sur "Autres couleurs…" à l'intérieur de ce popover. Le
/// bouton ✓ (ProjectColorSettingsView) qui appelle
/// `NSColorPanel.shared.close()` ne fermait donc RIEN tant que ce popover
/// SwiftUI (pas le panneau système) était affiché — bug constaté et
/// signalé explicitement le 2026-09-07. Ce swatch ouvre directement
/// `NSColorPanel.shared` lui-même (comme le fait n'importe quel vrai bouton
/// de couleur AppKit, ex. Pages/Keynote) : le bouton ✓ ferme alors bien LA
/// MÊME fenêtre qu'il a ouverte.
struct NativeColorSwatch: NSViewRepresentable {
    @Binding var color: Color
    var label: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showPanel))
        button.bezelStyle = .regularSquare
        button.isBordered = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.setButtonType(.momentaryPushIn)
        context.coordinator.button = button
        context.coordinator.applyColor(color)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyColor(color)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeColorSwatch
        weak var button: NSButton?

        init(_ parent: NativeColorSwatch) { self.parent = parent }

        func applyColor(_ color: Color) {
            button?.layer?.backgroundColor = NSColor(color).cgColor
        }

        @objc func showPanel() {
            let panel = NSColorPanel.shared
            panel.setTarget(self)
            panel.setAction(#selector(colorChanged(_:)))
            panel.color = NSColor(parent.color)
            panel.isContinuous = true
            panel.makeKeyAndOrderFront(nil)
        }

        @objc func colorChanged(_ sender: NSColorPanel) {
            parent.color = Color(sender.color)
        }
    }
}
