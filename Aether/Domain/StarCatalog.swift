import Foundation
import simd

/// Une étoile du Yale Bright Star Catalog : position équatoriale J2000,
/// magnitude visuelle et indice de couleur B-V. Type pur (pas de dépendance
/// Services). Le catalogue est embarqué sous forme binaire (`bsc5.bin`) ;
/// cf. `scripts/build_star_catalog.py` pour sa génération depuis la source ADC.
struct Star: Sendable, Equatable {
    /// Ascension droite J2000, radians.
    var rightAscension: Double
    /// Déclinaison J2000, radians.
    var declination: Double
    /// Magnitude visuelle apparente.
    var magnitude: Float
    /// Indice de couleur B-V (bleu < 0 < rouge). 0 si absent dans le catalogue.
    var colorIndex: Float
}

/// Une étoile résolue dans le ciel local : direction monde (convention Aether,
/// -Z = Nord, +X = Est, +Y = haut), magnitude et indice de couleur. Le fondu
/// d'horizon se fait côté shader à partir de `direction.y` (= sin(altitude)).
struct VisibleStar: Sendable, Equatable {
    var direction: SIMD3<Float>
    var magnitude: Float
    var colorIndex: Float
}

/// Chargement du catalogue et résolution des positions apparentes. Tout est pur
/// : la conversion équatorial → horizontal s'appuie sur le temps sidéral local
/// (formule de Meeus depuis la date julienne) et la latitude de l'observateur,
/// sans SwiftAA — la précision au degré suffit largement pour des points de
/// quelques pixels. Précession (J2000 → aujourd'hui, ~0,4°), nutation et
/// réfraction sont négligées (sous l'échelle visible).
enum StarCatalog {
    /// Étoiles émises jusqu'à une altitude légèrement négative : le fondu fin se
    /// fait dans le shader (sur `direction.y`), ce qui évite le *popping* à la
    /// frontière des buckets de temps.
    static let minAltitude: Double = -0.0175  // ≈ -1°

    /// Lit `bsc5.bin` du bundle. Enregistrements de 16 octets little-endian :
    /// float32 ra_rad, dec_rad, vmag, bv (cf. `build_star_catalog.py`).
    static func load(bundle: Bundle = .main) -> [Star] {
        guard let url = bundle.url(forResource: "bsc5", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return decode(data)
    }

    /// Décode les enregistrements binaires (exposé pour les tests).
    static func decode(_ data: Data) -> [Star] {
        let recordSize = 16
        let count = data.count / recordSize
        var stars: [Star] = []
        stars.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let base = i * recordSize
                let ra = raw.loadUnaligned(fromByteOffset: base, as: Float32.self)
                let dec = raw.loadUnaligned(fromByteOffset: base + 4, as: Float32.self)
                let vmag = raw.loadUnaligned(fromByteOffset: base + 8, as: Float32.self)
                let bv = raw.loadUnaligned(fromByteOffset: base + 12, as: Float32.self)
                stars.append(Star(
                    rightAscension: Double(ra), declination: Double(dec),
                    magnitude: vmag, colorIndex: bv))
            }
        }
        return stars
    }

    /// Temps sidéral apparent local, radians dans [0, 2π). `longitudeEast` en
    /// degrés (Est positif). Formule GMST de Meeus (chap. 12) depuis la date
    /// julienne ; la nutation (≤ ~1") est négligée → « moyen » plutôt
    /// qu'« apparent », sans incidence visible.
    static func localSiderealTime(date: Date, longitudeEast: Double) -> Double {
        let julianDay = date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
        let d = julianDay - 2_451_545.0
        let t = d / 36_525.0
        var gmst = 280.460_618_37 + 360.985_647_366_29 * d
            + 0.000_387_933 * t * t - (t * t * t) / 38_710_000.0
        gmst += longitudeEast
        let radians = gmst * .pi / 180.0
        let twoPi = 2.0 * Double.pi
        return radians - twoPi * (radians / twoPi).rounded(.down)
    }

    /// Résout les étoiles au-dessus de l'horizon (à `minAltitude` près) en
    /// directions monde, pour un lieu et un temps sidéral donnés. `latitude` en
    /// degrés. Azimut 0 = Nord, sens horaire = Est (convention `CelestialPosition`).
    static func visibleStars(
        _ stars: [Star], latitude: Double, siderealTime: Double
    ) -> [VisibleStar] {
        let phi = latitude * .pi / 180.0
        let sinPhi = sin(phi)
        let cosPhi = cos(phi)
        let sinMinAlt = sin(minAltitude)

        var visible: [VisibleStar] = []
        visible.reserveCapacity(stars.count / 2)
        for star in stars {
            let dec = star.declination
            let sinDec = sin(dec)
            let cosDec = cos(dec)
            let hourAngle = siderealTime - star.rightAscension
            let cosH = cos(hourAngle)

            let sinAlt = sinDec * sinPhi + cosDec * cosPhi * cosH
            if sinAlt < sinMinAlt {
                continue  // sous l'horizon
            }
            let altitude = asin(max(-1.0, min(1.0, sinAlt)))
            let sinH = sin(hourAngle)
            // Azimut depuis le Nord, sens horaire (cf. CelestialPosition).
            let azimuth = atan2(-sinH, tan(dec) * cosPhi - sinPhi * cosH)

            let position = CelestialPosition(body: .sun, azimuth: azimuth, altitude: altitude)
            visible.append(VisibleStar(
                direction: position.worldDirection,
                magnitude: star.magnitude,
                colorIndex: star.colorIndex))
        }
        return visible
    }
}
