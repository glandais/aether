/// Lecture « surcharge, sinon défaut » d'une valeur optionnelle, exposée en
/// subscript pour dériver un `Binding` non optionnel par chemin de clé
/// (`$hourOverride[orDefault: 12]`) au lieu d'un `Binding(get:set:)` à closures :
/// la lecture renvoie la surcharge ou le défaut, l'écriture pose la surcharge.
extension Optional where Wrapped: Hashable {
    subscript(orDefault fallback: Wrapped) -> Wrapped {
        get { self ?? fallback }
        set { self = newValue }
    }
}
