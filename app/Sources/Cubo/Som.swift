import AppKit

/// Som curto e suave que a app toca quando entra uma notificação (Recursos/chegou.wav).
@MainActor
enum Som {
    private static let som: NSSound? = {
        guard let url = Bundle.main.url(forResource: "chegou", withExtension: "wav") else { return NSSound(named: "Glass") }
        let s = NSSound(contentsOf: url, byReference: true)
        s?.volume = 0.8
        return s
    }()

    static func tocar() {
        guard let s = som else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}
