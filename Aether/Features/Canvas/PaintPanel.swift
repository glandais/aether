import SwiftUI

/// Panneau « Peinture » : tout le geste de dessin sur une seule carte —
/// sélecteur d'étage (visibilité), opacité du calque sélectionné, puis réglages
/// de pinceau (rayon, douceur). Sobre, façon éditeur d'images minimal. Les étages
/// sont listés du plus haut (cirrus) au plus bas (cumulus), comme on les lit dans
/// le ciel ; les réglages de pinceau, globaux, suivent sous un filet.
///
/// Frontière d'invalidation : le panneau ne lit **pas** `model.layers`. L'état des
/// étages lui arrive en résumé `Equatable` (`layers`, calculé par `CanvasView`) :
/// un point de trait (`extendStroke`) change les calques mais pas ce résumé, donc
/// ne réévalue pas ce panneau. Le modèle (`@Bindable`, comparé par identité) ne
/// sert qu'aux écritures et aux réglages que `CanvasView` ne lit pas : étage
/// actif, rayon et douceur du pinceau — glisser ces curseurs ne réinvalide que ce
/// panneau. En revanche l'opacité et la visibilité modifient `layers`, lus par le
/// rendu : les régler réévalue `CanvasView.body` (inhérent au rendu).
struct PaintPanel: View {
    /// Résumé d'un étage déjà peint (sa présence dans `layers` = l'étage existe).
    struct LayerSummary: Equatable {
        var isVisible: Bool
        var opacity: Float
    }

    @Bindable var model: CanvasModel
    /// État des étages peints, par genre (absent = étage vierge).
    let layers: [CloudGenus: LayerSummary]

    /// Résume les calques du modèle pour le panneau (visibilité, opacité par
    /// genre). Appelé par le parent, qui lit déjà `layers` pour le rendu.
    static func summaries(of model: CanvasModel) -> [CloudGenus: LayerSummary] {
        var result: [CloudGenus: LayerSummary] = [:]
        for genus in genusOrder {
            if let layer = model.layer(for: genus) {
                result[genus] = LayerSummary(isVisible: layer.isVisible, opacity: layer.opacity)
            }
        }
        return result
    }

    /// Étages affichés, du plus haut au plus bas.
    private static let genusOrder: [CloudGenus] = [.cirrus, .altocumulus, .cumulus]

    var body: some View {
        let active = model.activeGenus
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.genusOrder, id: \.self) { genus in
                genusRow(genus, active: genus == active)
            }
            Divider()
            opacityControl(for: active)
            Divider()
            brushSlider(
                icon: "smallcircle.filled.circle",
                value: $model.brushRadius, range: 0.03...0.25)
            brushSlider(
                icon: "drop",
                value: $model.brushSoftness, range: 0...1)
        }
        .frame(width: 230)
    }

    /// Ligne d'un étage : sélection (nom), et — si le calque porte des traits — un
    /// œil de visibilité. Le nom sélectionne le calque actif (la peinture y va).
    @ViewBuilder
    private func genusRow(_ genus: CloudGenus, active: Bool) -> some View {
        let layer = layers[genus]
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.selectGenus(genus) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .font(.footnote)
                        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    let dimmed = layer?.isVisible == false
                    Text(Self.genusName(genus))
                        .font(.callout)
                        .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])

            if let layer {
                Button {
                    model.setVisible(!layer.isVisible, for: genus)
                } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(layer.isVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "layer.visibility", table: "Aether")))
                .accessibilityValue(Text(String(
                    localized: layer.isVisible ? "layer.visible" : "layer.hidden", table: "Aether")))
            }
        }
    }

    /// Curseur d'opacité du calque sélectionné. Inactif (grisé) tant que l'étage
    /// est vierge — rien à doser sans matière peinte.
    @ViewBuilder
    private func opacityControl(for genus: CloudGenus) -> some View {
        let layer = layers[genus]
        // Lecture depuis le résumé (valeur), écriture vers le modèle : pas de
        // lecture de `model.layers` dans ce panneau. Étage vierge → 1 (curseur
        // de toute façon inactif).
        let opacity = Binding(
            get: { layer?.opacity ?? 1 },
            set: { model.setOpacity($0, for: genus) })
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(
                value: opacity,
                in: 0...1,
                onEditingChanged: { editing in
                    // Au début du geste seulement : un instantané d'historique,
                    // pour que l'annulation revienne à l'opacité d'avant-réglage.
                    if editing { model.snapshotForOpacity(of: genus) }
                }
            )
            .tint(.white.opacity(0.55))
            .disabled(layer == nil)
        }
        .opacity(layer == nil ? 0.4 : 1)
        .accessibilityLabel(Text(String(localized: "layer.opacity", table: "Aether")))
    }

    /// Nom sobre d'un genre (registre atmosphérique).
    private static func genusName(_ genus: CloudGenus) -> String {
        switch genus {
        case .cirrus: String(localized: "layer.cirrus", table: "Aether")
        case .altocumulus: String(localized: "layer.altocumulus", table: "Aether")
        case .cumulus: String(localized: "layer.cumulus", table: "Aether")
        }
    }

    private func brushSlider(icon: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: value, in: range).tint(.white.opacity(0.55))
        }
    }
}
