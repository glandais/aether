import simd

/// Géométrie de la phase lunaire, en espace monde, à partir des **seules**
/// directions apparentes du Soleil et de la Lune. La phase (croissant → pleine)
/// émerge naturellement de l'angle entre les deux : Soleil ≈ Lune → nouvelle
/// (disque sombre), Soleil ≈ −Lune → pleine (disque éclairé). Aucune donnée
/// astronomique supplémentaire (fraction éclairée, angle de phase) n'est requise.
///
/// Type pur Domain (ne dépend de rien). Le shader `Background.metal` (`moonDisc`)
/// reproduit la **même** formule ; ces helpers permettent de la tester unitairement
/// (Metal n'étant pas testable), à l'image du couple CPU/GPU de `Atmosphere`.
///
/// Convention monde Aether : -Z = Nord, +X = Est, +Y = haut. Les vecteurs passés
/// sont supposés unitaires.
enum MoonPhase {
    /// Direction du limbe éclairé : projection du Soleil dans le plan tangent du
    /// disque lunaire (perpendiculaire à `moon`). C'est l'axe vers lequel pointe
    /// la corne du croissant. Repli orthogonal fini quand Soleil ∥ ±Lune
    /// (nouvelle/pleine lune, projection nulle) pour éviter tout NaN.
    static func brightLimbDirection(moon: SIMD3<Float>, sun: SIMD3<Float>) -> SIMD3<Float> {
        let proj = sun - simd_dot(sun, moon) * moon
        if simd_length(proj) > 1e-4 {
            return simd_normalize(proj)
        }
        // Soleil colinéaire à la Lune : n'importe quelle tangente convient.
        let reference: SIMD3<Float> = abs(moon.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        return simd_normalize(simd_cross(moon, reference))
    }

    /// Terme d'éclairement de la surface lunaire au point du disque `(a, b)`
    /// (coordonnées normalisées : `a` le long du limbe éclairé, `b` perpendiculaire,
    /// `a² + b² ≤ 1` sur le disque). Reconstruit la normale de l'hémisphère visible
    /// puis renvoie `dot(n, soleil)` : positif = éclairé, négatif = dans l'ombre.
    /// Le terminateur (frontière) est l'isovaleur 0.
    static func surfaceLit(a: Float, b: Float, moon: SIMD3<Float>, sun: SIMD3<Float>) -> Float {
        let brightDir = brightLimbDirection(moon: moon, sun: sun)
        let tangent = simd_cross(moon, brightDir)
        // Normale de l'hémisphère face à l'œil : `-moon` car `moon` pointe de
        // l'œil vers la Lune (la face visible regarde donc vers l'œil).
        let h = (max(0, 1 - a * a - b * b)).squareRoot()
        let normal = a * brightDir + b * tangent - h * moon
        return simd_dot(normal, sun)
    }
}
