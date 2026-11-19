import CoreGraphics
import Foundation

/// Lembrete de pausa: ao fim de 50 min seguidos ao computador, o cubo sugere levantar.
/// Conta como pausa ficar 5 min sem mexer no teclado nem no rato.
@MainActor
final class Pausa {
    static let shared = Pausa()
    var enviar: (([String: String]) -> Void)?
    var podeAvisar: () -> Bool = { true }

    private var ativoDesde = Date()
    private var timer: Timer?
    static let minutos: Double = 50

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Pausa.shared.verificar() }
        }
    }

    private func verificar() {
        let parado = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                             eventType: CGEventType(rawValue: ~0)!)
        if parado >= 300 { ativoDesde = Date(); return }
        guard Date().timeIntervalSince(ativoDesde) >= Self.minutos * 60 else { return }
        ativoDesde = Date()
        guard podeAvisar() else { return }
        enviar?(["app": "Cubo", "titulo": "Hora de uma pausa",
                 "texto": "Ja estas ha 50 min ao computador. Levanta-te, bebe agua e estica as pernas!"])
    }
}
