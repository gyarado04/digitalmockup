import Foundation
import Observation

/// Réglages de la page projet à 2 colonnes (ProjectView : site/pages/plans
/// à gauche, aperçu du rendu à droite — voir ProjectView.swift).
///
/// `rightColumnWidth` N'EST PAS une valeur par défaut à deviner puis
/// figer dans le code — l'utilisateur a explicitement refusé cette
/// approche ("je veux pas des valeurs en dure, je veux pouvoir glisser
/// pour ajuster la taille de la colonne", 2026-09-03). C'est une
/// préférence VIVANTE : ProjectView expose une poignée qu'on glisse à la
/// souris entre les 2 colonnes (voir `ColumnResizeHandle` dans
/// ProjectView.swift), qui appelle `setRightColumnWidth` en direct pendant
/// le glissement. La valeur est aussi mémorisée dans UserDefaults pour
/// rester d'une session à l'autre.
///
/// `columnSpacing`, lui, a été trouvé à la main via un panneau de réglage
/// temporaire (retiré le 2026-09-03, "retire les boutons de panneau de
/// contrôle" — chantier considéré clos) puis figé en constante.
@MainActor
@Observable
final class ProjectViewSpacing {
    static let shared = ProjectViewSpacing()

    static let columnSpacing: Double = 36

    /// Plancher absolu (la colonne aperçu ne devient jamais illisible) et
    /// PLAFOND purement défensif (une valeur absurde ne peut jamais être
    /// stockée) — PAS la vraie limite haute du glissement au quotidien.
    /// Un plafond fixe ici (560 à l'origine) faisait "bloquer" le
    /// glissement bien avant le bord de la fenêtre sur un grand écran,
    /// signalé explicitement par l'utilisateur le 2026-09-03 ("quand je
    /// bouge le séparateur, elle bloque à un certain point... comme si
    /// elle avait une largeur minimum" — en fait la colonne de GAUCHE qui
    /// ne pouvait plus rétrécir puisque la droite ne pouvait plus
    /// grandir). La vraie limite haute est maintenant dynamique, calculée
    /// depuis la largeur réelle de la fenêtre par l'appelant (voir
    /// `ColumnResizeHandle`/`ProjectView.body`) et passée via `maxAllowed`.
    static let rightColumnWidthRange: ClosedRange<Double> = 260...4000
    private static let rightColumnWidthDefault: Double = 380
    private static let rightColumnWidthDefaultsKey = "projectView.rightColumnWidth"

    /// Propriété STOCKÉE (pas calculée à la volée depuis UserDefaults) —
    /// même piège déjà rencontré une fois avec `hasChosenProjectsRoot`
    /// dans AppState.swift : `@Observable` ne suit que les propriétés
    /// stockées, jamais une propriété calculée qui lit une source externe.
    private(set) var rightColumnWidth: Double

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.rightColumnWidthDefaultsKey)
        rightColumnWidth = stored > 0 ? stored : Self.rightColumnWidthDefault
    }

    /// Appelée en direct pendant le glissement de la poignée — clampe dans
    /// `rightColumnWidthRange`, ET dans `maxAllowed` si fourni (limite
    /// dynamique dérivée de la largeur réelle de la fenêtre à cet instant,
    /// pour ne jamais écraser la colonne de gauche en dessous d'un
    /// minimum) — puis persiste dans UserDefaults à chaque changement.
    func setRightColumnWidth(_ newValue: Double, maxAllowed: Double? = nil) {
        let upperBound = maxAllowed.map { min($0, Self.rightColumnWidthRange.upperBound) } ?? Self.rightColumnWidthRange.upperBound
        let clamped = min(max(newValue, Self.rightColumnWidthRange.lowerBound), upperBound)
        rightColumnWidth = clamped
        UserDefaults.standard.set(clamped, forKey: Self.rightColumnWidthDefaultsKey)
    }
}
