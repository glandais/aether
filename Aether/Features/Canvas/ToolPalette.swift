import SwiftUI

/// Panneau d'outil du canvas. Exclusif : un seul à la fois, pour ne pas
/// encombrer le ciel ni déborder en paysage. `paint` réunit la peinture
/// (sélection d'étage, visibilité, opacité, réglages de pinceau) ; il s'affiche
/// de lui-même tant qu'on peint, sans bascule. `more` regroupe les réglages
/// contextuels (ciel, lieu) sous un seul bouton, façon « More » HIG.
enum CanvasToolPanel {
    case paint, more
}

/// Palette d'outils, axe adaptatif : colonne en portrait, rangée en paysage
/// (hauteur compacte). La bascule « Options » est toujours visible ; ouverte,
/// elle révèle regard, édition (annuler/rétablir/effacer), pinceau et « More »
/// (ciel + lieu). Le panneau actif flotte **à côté** des pastilles (carte
/// `ultraThinMaterial`) sans jamais les repousser : à gauche de la colonne
/// (portrait), sous la rangée (paysage). C'est ce découplage qui supprime le
/// débordement en paysage.
///
/// Entrées étroites : bascules liées (options, panneau, mode regard), état
/// d'édition en valeurs simples et actions en closures ; le contenu du panneau
/// est fourni par `CanvasView` (`panelContent`).
struct ToolPalette<PanelContent: View>: View {
    /// Révèle toutes les options (regard, pinceau, édition, « More »).
    @Binding var showOptions: Bool
    /// Panneau explicitement ouvert (seul « More » s'y pose).
    @Binding var activePanel: CanvasToolPanel?
    /// Mode regard (`true`) ou dessin (`false`), mutuellement exclusifs.
    @Binding var isRotating: Bool
    let canUndo: Bool
    let canRedo: Bool
    let hasStrokes: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onClear: () -> Void
    @ViewBuilder let panelContent: (CanvasToolPanel) -> PanelContent

    /// Hauteur compacte (paysage iPhone) : la palette passe en rangée
    /// horizontale, la largeur (abondante) absorbant les pastilles.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if isCompactHeight {
            VStack(alignment: .trailing, spacing: 12) {
                bubbleStack
                activePanelCard
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                activePanelCard
                bubbleStack
            }
        }
    }

    /// Paysage iPhone (la palette passe à l'horizontale).
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    /// Y a-t-il quelque chose à éditer (trait en cours ou historique) ? Conditionne
    /// l'apparition des pastilles d'édition.
    private var hasEdits: Bool { canUndo || canRedo || hasStrokes }

    /// La pile de pastilles (axe adaptatif), sans le panneau.
    @ViewBuilder
    private var bubbleStack: some View {
        let reveal = AnyTransition.opacity.combined(
            with: .move(edge: isCompactHeight ? .trailing : .top))
        let bubbles = Group {
            optionsButton
            if showOptions {
                rotateButton.transition(reveal)
                brushBubble.transition(reveal)
                // Annuler / rétablir / effacer : pastilles principales directes
                // (pas de sous-menu), révélées seulement dès qu'il y a à éditer.
                if hasEdits {
                    actionBubble("arrow.uturn.backward", "action.undo", enabled: canUndo, action: onUndo)
                        .transition(reveal)
                    actionBubble("arrow.uturn.forward", "action.redo", enabled: canRedo, action: onRedo)
                        .transition(reveal)
                    actionBubble("trash", "action.clear", enabled: hasStrokes, action: onClear)
                        .transition(reveal)
                }
                moreBubble.transition(reveal)
            }
        }
        if isCompactHeight {
            HStack(alignment: .top, spacing: 10) { bubbles }
        } else {
            VStack(alignment: .trailing, spacing: 10) { bubbles }
        }
    }

    /// Carte du panneau visible, en matériau translucide : « More » s'il est
    /// ouvert ; sinon, en mode dessin (options déployées), la carte peinture
    /// (sélection d'étage, visibilité, opacité, réglages de pinceau) — toujours
    /// présente tant qu'on peint, sans bascule.
    @ViewBuilder
    private var activePanelCard: some View {
        let panel: CanvasToolPanel? =
            activePanel == .more ? .more
            : (showOptions && !isRotating ? .paint : nil)
        if let panel {
            panelContent(panel)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
        }
    }

    /// Bascule unique « Options » : repliée, elle garde le ciel dégagé ; ouverte,
    /// elle révèle d'un geste l'ensemble des réglages (regard, pinceau, heure).
    private var optionsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showOptions.toggle()
                if !showOptions { activePanel = nil }  // replier referme tout panneau
            }
        } label: {
            bubbleLabel("slider.horizontal.3", active: showOptions)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "mode.options", table: "Aether")))
    }

    /// Sélecteur du mode « regard » : mutuellement exclusif du mode dessin
    /// (jumeau du bouton pinceau). Sélectionner le regard sort du dessin.
    private var rotateButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isRotating = true }
        } label: {
            bubbleLabel("arrow.up.and.down.and.arrow.left.and.right", active: isRotating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "mode.lookAround", table: "Aether")))
    }

    /// Sélecteur du mode « dessin » : mutuellement exclusif du mode regard.
    /// Sélectionner le dessin referme « More » pour laisser les réglages de
    /// pinceau visibles tant qu'on peint.
    private var brushBubble: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isRotating = false
                // Referme « More » pour révéler la carte peinture (étages +
                // pinceau) tant qu'on peint.
                activePanel = nil
            }
        } label: {
            bubbleLabel("paintbrush.pointed", active: !isRotating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "group.brush", table: "Aether")))
    }

    /// Pastille « More » : regroupe les réglages contextuels (ciel, lieu).
    /// Bascule exclusive : l'ouvrir referme tout autre panneau.
    private var moreBubble: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                activePanel = (activePanel == .more) ? nil : .more
            }
        } label: {
            bubbleLabel("ellipsis", active: activePanel == .more)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "group.more", table: "Aether")))
    }

    /// Pastille circulaire de taille **uniforme** quelle que soit la largeur du
    /// symbole (sinon les cercles diffèrent et s'alignent mal). Teintée si active.
    private func bubbleLabel(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .padding(13)
            .background(.ultraThinMaterial, in: Circle())
    }

    /// Pastille-action principale (annuler/rétablir/effacer) : déclenche une
    /// action sans panneau, grisée quand indisponible. Même pastille circulaire
    /// que les bascules, pour un alignement homogène dans la palette.
    private func actionBubble(
        _ icon: String, _ label: String.LocalizationValue,
        enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
                .padding(13)
                .background(.ultraThinMaterial, in: Circle())
                // Pastille entière atténuée quand indisponible : un glyphe
                // tertiaire seul serait illisible sur l'horizon clair.
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(String(localized: label, table: "Aether")))
    }
}
