import simd

/// Genre de nuage : fixe l'étage (rayons de la coquille), le profil vertical
/// (`cloudType` pour `densityHeightGradient`) et le caractère du bruit. Source
/// unique des constantes par étage — l'analogue météo de `CloudParameters`.
///
/// Modèle multi-coquilles (cf. `docs/SHELLS.md` §4) : chaque genre décrit une
/// coquille sphérique concentrique enveloppant la « petite planète » de la
/// référence `realtime_clouds`. L'empilement des coquilles crée les étages
/// (cumulus bas, altocumulus moyen, cirrus haut) ; `height_fraction` opère
/// *dans* chaque coquille, pas entre elles.
enum CloudGenus: String, Codable, Sendable, CaseIterable {
    case cirrus       // haut, mince, fibreux
    case altocumulus  // moyen, floconneux
    case cumulus      // bas, épais, bourgeonnant

    /// Constantes de la coquille de ce genre. Rayons illustratifs (à caler par
    /// capture, cf. §12) ; ordonnés en étages disjoints et croissants
    /// (cumulus < altocumulus < cirrus).
    var shell: ShellSpec {
        switch self {
        case .cirrus:
            ShellSpec(inner: 207_000, outer: 207_600, cloudType: 0.05,
                      noiseScale: 6.4e-4, drift: SIMD2(0.030, 0.004))
        case .altocumulus:
            ShellSpec(inner: 204_000, outer: 205_000, cloudType: 0.45,
                      noiseScale: 3.9e-4, drift: SIMD2(0.016, 0.006))
        case .cumulus:
            ShellSpec(inner: 201_000, outer: 203_000, cloudType: 0.85,
                      noiseScale: 3.0e-4, drift: SIMD2(0.010, 0.004))
        }
    }
}

/// Constantes d'une coquille, dérivées du genre. (Rayons illustratifs.)
///
/// `noiseScale` est en **coordonnées planète** (m⁻¹, ordre ~3·10⁻⁴) : le
/// raymarch coquille opère à `p ≈ 2·10⁵ m` et la référence sample son bruit à
/// `p * 0.0003` (`Sky.metal:548`). Ce n'est **pas** le `kNoiseScale = 0.42`
/// des cubes, calé sur les unités monde — l'utiliser tel quel donnerait de
/// l'aliasing pur (cf. `docs/SHELLS.md` §4, note d'unités).
struct ShellSpec: Sendable, Equatable {
    /// Rayons (m au-dessus du centre planète), `inner < outer`.
    var inner: Float
    var outer: Float
    /// Profil vertical : 0 stratus aplati … 1 cumulus bourgeonnant.
    var cloudType: Float
    /// Échelle du bruit 3D, m⁻¹, en coordonnées planète (cf. note de type).
    var noiseScale: Float
    /// Dérive du bruit dans le temps (la couverture peinte, elle, reste fixe).
    var drift: SIMD2<Float>
}

/// Une coquille éditable = un calque. Concentrique aux autres ; porte ses traits
/// (carte de couverture par direction) et ses paramètres météo. L'étage vient du
/// `genus` (rayons de la coquille), pas d'une direction de regard ancrée.
struct CloudLayer: Equatable, Sendable, Codable {
    var genus: CloudGenus
    /// Traits du calque — `BrushStroke` inchangé (points écran [0,1]² + pose au
    /// dépôt). Seule la cible de cuisson change (carte 2D directionnelle).
    var strokes: [BrushStroke]
    /// Ex-`CloudParameters.coverageBias`, désormais par calque.
    var coverageBias: Float
    /// Ex-`CloudParameters.densityScale` : opacité (extinction) du calque.
    var opacity: Float
    /// Toggle de visibilité du calque (éditeur d'images).
    var isVisible: Bool

    init(
        genus: CloudGenus,
        strokes: [BrushStroke] = [],
        coverageBias: Float = 0,
        opacity: Float = 1,
        isVisible: Bool = true
    ) {
        self.genus = genus
        self.strokes = strokes
        self.coverageBias = coverageBias
        self.opacity = opacity
        self.isVisible = isVisible
    }

    /// Un calque par étage + marge. **Source unique** de la borne : la création
    /// (`CanvasModel`), l'atlas de couverture (`Renderer`) et le raymarch
    /// concentrique (`Cloud.metal`) s'y réfèrent.
    static let maxCount = 4
}
