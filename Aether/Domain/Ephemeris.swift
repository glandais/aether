import Foundation

/// Lever / coucher d'un astre sur un jour donné à un lieu donné.
enum RiseSetState: Equatable, Sendable {
    /// L'astre franchit l'horizon ce jour-là. Un instant peut être `nil` si le
    /// lever (ou le coucher) ne tombe pas dans la journée locale.
    case rises(rise: Date?, set: Date?)
    /// L'astre reste **au-dessus** de l'horizon tout le jour (soleil de minuit,
    /// lune circumpolaire — typique des hautes latitudes en été, ex. Cap Nord).
    case alwaysUp
    /// L'astre reste **sous** l'horizon tout le jour (nuit polaire).
    case alwaysDown
}

/// Éphéméride d'un lieu et d'un jour : lever / coucher du Soleil et de la Lune,
/// et état de la Lune (phase + fraction éclairée). Les instants sont absolus
/// (`Date`) ; l'affichage local relève du fuseau de la scène. Type pur.
struct Ephemeris: Sendable {
    var sun: RiseSetState
    var moon: RiseSetState
    var moonPhase: LunarPhase
    /// Fraction éclairée du disque lunaire, de 0 (nouvelle) à 1 (pleine).
    var moonIllumination: Double
}
