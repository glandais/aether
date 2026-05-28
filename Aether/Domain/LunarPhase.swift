/// Phase lunaire en huit phases canoniques, déterminée par l'écart de longitude
/// écliptique Lune − Soleil (0° = nouvelle lune, 180° = pleine lune ; 0→180
/// croissante, 180→360 décroissante). Type pur (couche Domain). Distinct de
/// `MoonPhase`, qui porte la *géométrie* du disque éclairé.
enum LunarPhase: Sendable {
    case newMoon
    case waxingCrescent
    case firstQuarter
    case waxingGibbous
    case fullMoon
    case waningGibbous
    case lastQuarter
    case waningCrescent
}
