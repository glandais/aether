/// Paramètres de rendu du nuage dérivés de la météo (étape 9). Type pur :
/// la météo statique du paysage curé informe l'état initial du nuage peint.
struct CloudParameters: Equatable, Sendable {
    /// Biais de couverture ajouté à la silhouette peinte. Couvert → nuages plus
    /// pleins ; dégagé → plus clairsemés et érodés.
    var coverageBias: Float
    /// Multiplicateur d'opacité (extinction). Humide/couvert → plus opaque.
    var densityScale: Float

    /// État neutre, avant toute résolution météo.
    static let neutral = CloudParameters(coverageBias: 0.0, densityScale: 1.0)

    init(coverageBias: Float, densityScale: Float) {
        self.coverageBias = coverageBias
        self.densityScale = densityScale
    }

    /// Mappe un instantané météo vers les paramètres de rendu.
    init(weather: WeatherSnapshot) {
        let cover = Float(weather.cloudCover)   // 0…1
        let humidity = Float(weather.humidity)  // 0…1
        // Ciel dégagé → silhouette plus érodée (biais négatif) ; couvert → plus
        // pleine (biais positif). Humidité et couverture épaississent le nuage.
        coverageBias = (cover - 0.5) * 0.4                  // ≈ -0.2…+0.2
        densityScale = 0.6 + cover * 0.6 + humidity * 0.2   // ≈ 0.6…1.4
    }
}
