import Foundation

/// Portage de app/core/templates.py:plan_category / PLAN_CATEGORIES —
/// catégorise un plan (caméra) d'après la convention de nommage "<nom> -
/// <Catégorie>" (ex. "Plan 3 - Desktop", voir
/// templates/tablette/template.blend depuis le 2026-09-01).
public enum PlanCategory {
    /// Ordre canonique d'affichage — même ordre que côté Python.
    public static let known: [String] = ["Desktop", "Transition", "Mobile"]

    /// `nil` si le nom ne suit pas cette convention (plan d'un futur
    /// template pas encore catégorisé, ou caméra hors convention) — pas
    /// une erreur, juste "pas catégorisé" (groupe "Autres" côté UI).
    public static func of(_ cameraName: String) -> String? {
        guard !cameraName.isEmpty, cameraName.contains(" - ") else { return nil }
        guard let range = cameraName.range(of: " - ", options: .backwards) else { return nil }
        let suffix = cameraName[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return known.first { $0.lowercased() == suffix.lowercased() }
    }

    /// Partitionne des noms de caméras par catégorie, dans l'ordre
    /// canonique de `known` puis alphabétique pour tout groupe hors
    /// convention, "Autres" en dernier pour les caméras sans groupe —
    /// SEULEMENT si au moins une caméra a un groupe (sinon un groupe
    /// unique `[(nil, names)]`, comme côté Python : _group_items).
    public static func grouped(_ names: [String]) -> [(String?, [String])] {
        guard names.contains(where: { of($0) != nil }) else { return [(nil, names)] }

        var buckets: [String: [String]] = [:]
        var others: [String] = []
        for name in names {
            if let category = of(name) {
                buckets[category, default: []].append(name)
            } else {
                others.append(name)
            }
        }

        var result: [(String?, [String])] = []
        for label in known {
            if let bucket = buckets.removeValue(forKey: label) {
                result.append((label, bucket))
            }
        }
        for label in buckets.keys.sorted() {
            result.append((label, buckets[label] ?? []))
        }
        if !others.isEmpty {
            result.append(("Autres", others))
        }
        return result
    }
}
