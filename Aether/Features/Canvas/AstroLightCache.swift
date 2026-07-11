import Foundation
import simd

/// Part **astro-dépendante** de l'éclairage résolu : tout ce qui ne dépend que de
/// l'instant (`date`) et du lieu (`coordinate`) — positions du Soleil et de la
/// Lune, illumination, transmittances solaires et intégrales CPU de radiance du
/// ciel. C'est la moitié coûteuse de `ResolvedLight` (deux positions SwiftAA,
/// deux intégrales de scattering à 16 pas). Elle est invariante tant que l'heure
/// et le lieu ne changent pas : peindre, régler un pinceau ou tourner le regard
/// ne la recalcule pas.
///
/// La part « regard » (mélange des directions caméra Soleil/Lune avec le
/// lacet/tangage) reste bon marché et vit dans `CanvasView.body`, à partir de
/// `sunWeight` et des positions ci-dessous.
struct CachedAstroLight {
    var sunPosition: CelestialPosition
    var moonPosition: CelestialPosition
    var skySunDirection: SIMD3<Float>
    var moonSkyDirection: SIMD3<Float>
    var sunDiscColor: SIMD3<Float>
    var moonDiscColor: SIMD3<Float>
    var color: SIMD3<Float>
    var ambient: SIMD3<Float>
    var groundLight: Float
    var isDaytime: Bool
    var moonGlint: SIMD3<Float>
    var nightWeight: Float
    var skyZenithRadiance: SIMD3<Float>
    var skyHorizonRadiance: SIMD3<Float>
    /// Poids diurne (0 nuit → 1 jour), pour le mélange des directions caméra.
    var sunWeight: Float
}

extension CachedAstroLight {
    // Échelles ramenant la radiance atmosphérique dans la plage de travail du
    // nuage (réglées par capture). La couleur/teinte vient de l'atmosphère ; ces
    // facteurs ne font que caler la luminosité.
    private static let cloudSunStrength: Float = 12
    private static let cloudAmbientStrength: Float = 1.2
    /// Désaturation de l'ambiance bleue du ciel (0 = gris, 1 = bleu ciel pur),
    /// pour éviter que le corps du nuage ne vire au gris-bleu.
    private static let ambientSaturation: Float = 0.5
    /// Luminosités des disques solaire/lunaire dessinés dans le ciel (réglées par
    /// capture). Le soleil sature vers le blanc ; la lune reste tamisée.
    private static let sunDiscBrightness: Float = 1.3
    private static let moonDiscBrightness: Float = 0.9
    /// Blanc froid du disque lunaire (la phase/teinte vient de la géométrie).
    private static let moonDiscTint = SIMD3<Float>(0.85, 0.88, 1.0)

    /// Résout la part astro-dépendante de l'éclairage pour un instant et un lieu.
    /// Soleil le jour, lune la nuit (fondu au crépuscule), calé sur l'exposition.
    static func resolve(
        date: Date, coordinate: GeoCoordinate,
        astro: AstroService, atmosphere: Atmosphere, exposure: Float
    ) -> CachedAstroLight {
        let sun = astro.position(of: .sun, at: coordinate, date: date)
        let moon = astro.position(of: .moon, at: coordinate, date: date)
        let illumination = astro.moonIlluminatedFraction(date: date)

        // 1 quand le soleil est levé, 0 la nuit ; fondu dans la bande crépusculaire.
        let sunWeight = SkyLighting.smoothstep(-0.08, 0.06, Float(sun.altitude))
        let moonLight = MoonLighting(moonAltitude: moon.altitude, illuminatedFraction: illumination)

        // Éclairage du nuage dérivé de la **même** atmosphère que le ciel :
        // soleil = transmittance solaire (chaud bas, blanc haut, nul la nuit) ;
        // ambiance = radiance du ciel au zénith (bleue le jour), désaturée pour
        // garder un nuage clair plutôt que gris-bleu.
        let sunWorld = sun.worldDirection
        let sunDayColor = atmosphere.sunTransmittance(sunDirection: sunWorld) * cloudSunStrength
        let zenith = atmosphere.skyRadiance(viewDirection: SIMD3(0, 1, 0), sunDirection: sunWorld)
        // Radiance du ciel près de l'horizon, dans l'azimut du soleil (pour la
        // chaleur du reflet bas), avec repli vers le Nord si le soleil est haut.
        let sunHoriz = SIMD3<Float>(sunWorld.x, 0, sunWorld.z)
        let horizonDir = length(sunHoriz) > 0.05
            ? normalize(SIMD3<Float>(sunHoriz.x, 0.08, sunHoriz.z))
            : SIMD3<Float>(0, 0.08, -1)
        let horizonRadiance = atmosphere.skyRadiance(viewDirection: horizonDir, sunDirection: sunWorld)
        let zenithLuma = 0.2126 * zenith.x + 0.7152 * zenith.y + 0.0722 * zenith.z
        let ambientDayColor =
            (SIMD3(repeating: zenithLuma) + (zenith - SIMD3(repeating: zenithLuma)) * ambientSaturation)
            * cloudAmbientStrength

        let color = (sunDayColor * sunWeight + moonLight.color * (1 - sunWeight)) * exposure
        let ambient = (ambientDayColor * sunWeight + moonLight.ambient * (1 - sunWeight)) * exposure

        // Sol éclairé par le jour, avec un plancher lunaire (pas de bande claire
        // sous un ciel noir de minuit).
        let moonLuma = 0.2126 * moonLight.color.x + 0.7152 * moonLight.color.y + 0.0722 * moonLight.color.z
        let groundLight = max(sunWeight, min(moonLuma * 0.06, 0.15), 0.02)

        // Couleurs des disques. Le soleil réutilise la transmittance solaire
        // (chaude bas, blanche haut, nulle sous l'horizon → disque qui s'éteint
        // seul). La lune est un blanc froid atténué par son altitude ; la phase
        // (croissant/gibbeuse) est calculée côté shader, donc pas de produit par
        // la fraction éclairée ici.
        let sunDiscColor = atmosphere.sunTransmittance(sunDirection: sunWorld)
            * exposure * sunDiscBrightness
        let moonAltitudeFade = SkyLighting.smoothstep(-0.02, 0.05, Float(moon.altitude))
        let moonDiscColor = moonDiscTint * (moonAltitudeFade * moonDiscBrightness)

        return CachedAstroLight(
            sunPosition: sun, moonPosition: moon,
            skySunDirection: sun.worldDirection, moonSkyDirection: moon.worldDirection,
            sunDiscColor: sunDiscColor, moonDiscColor: moonDiscColor,
            color: color, ambient: ambient, groundLight: groundLight,
            isDaytime: sunWeight >= 0.5,
            moonGlint: moonLight.color * exposure, nightWeight: 1 - sunWeight,
            skyZenithRadiance: zenith, skyHorizonRadiance: horizonRadiance,
            sunWeight: sunWeight)
    }
}

/// Cache synchrone de l'éclairage astro-dépendant, gardé en `@State` par
/// `CanvasView`. Il ne recalcule que quand la clé (instant, lieu) change et
/// renvoie sinon la valeur stockée — la mémoïsation synchrone évite tout retard
/// d'une image sur l'éclairage pendant le glissement d'heure / le défilement
/// (une reconstruction asynchrone via `.task` accuserait un décalage).
///
/// Classe **non** `@Observable` et non mutée via `@State` : l'appeler depuis
/// `body` n'y crée aucune dépendance d'invalidation.
@MainActor
final class AstroLightCache {
    private struct Key: Equatable {
        var date: Date
        var coordinate: GeoCoordinate
    }

    private var key: Key?
    private var cached: CachedAstroLight?

    /// Renvoie l'éclairage astro-dépendant, recalculé seulement si (instant, lieu)
    /// a changé. `exposure` est constant sur la durée de vie de la vue (propre à
    /// la scène), donc hors clé.
    func resolved(
        date: Date, coordinate: GeoCoordinate,
        astro: AstroService, atmosphere: Atmosphere, exposure: Float
    ) -> CachedAstroLight {
        let requested = Key(date: date, coordinate: coordinate)
        if let cached, key == requested {
            return cached
        }
        let value = CachedAstroLight.resolve(
            date: date, coordinate: coordinate,
            astro: astro, atmosphere: atmosphere, exposure: exposure)
        key = requested
        cached = value
        return value
    }
}
