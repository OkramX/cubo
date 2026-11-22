import AppKit

/// Som curto que a app toca quando entra uma notificação.
/// Usa ~/Library/Application Support/Cubo/chegou.wav se existir (trocar o som sem reinstalar);
/// senão o que vem na app (Recursos/chegou.wav).
@MainActor
enum Som {
    private static let som: NSSound? = {
        let proprio = CuboConfig.pasta.appendingPathComponent("chegou.wav")
        let url = FileManager.default.fileExists(atPath: proprio.path) ? proprio
            : Bundle.main.url(forResource: "chegou", withExtension: "wav")
        guard let url else { return NSSound(named: "Glass") }
        let s = NSSound(contentsOf: url, byReference: true)
        s?.volume = 0.8
        return s
    }()

    /// Som diferente para as pessoas VIP
    static func tocarVip() {
        let s = NSSound(named: "Hero") ?? NSSound(named: "Glass")
        s?.volume = 1
        s?.play()
    }

    static func tocar() {
        guard let s = som else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}
