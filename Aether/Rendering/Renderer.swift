import MetalKit
import os

/// Rendu minimal de l'étape 1 : efface l'écran avec une couleur atmosphérique.
/// Les étapes suivantes du pipeline (raymarching, volume textures, scattering)
/// enrichiront `draw(in:)`.
final class Renderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let log = Logger(subsystem: "io.github.glandais.aether", category: "Renderer")

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            // Pas de force-unwrap : sans device Metal, on n'instancie pas le renderer.
            return nil
        }
        self.commandQueue = queue
        super.init()

        view.device = device
        // Bleu crépusculaire sobre — placeholder en attendant le paysage (étape 1).
        view.clearColor = MTLClearColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1.0)
        log.debug("Renderer initialisé sur \(device.name, privacy: .public)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Aucun état dépendant de la taille à recalculer pour l'instant.
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        // Passe vide : le `loadAction = .clear` applique la clearColor du MTKView.
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
