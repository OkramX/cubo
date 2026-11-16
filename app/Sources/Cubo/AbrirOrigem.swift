import AppKit
import ApplicationServices

/// Abre a notificação no sítio certo da app de origem.
enum AbrirOrigem {
    static let whatsapp = "net.whatsapp.whatsapp"

    static func abrir(_ i: ItemEntrada, senao abrirApp: () -> Void) {
        // 1) Link direto deixado pela própria app (ex.: Calendário)
        if let l = i.link, let u = URL(string: l), NSWorkspace.shared.open(u) { return }

        switch i.bundle.lowercased() {
        case whatsapp:
            // Conversa com número de telefone: abre diretamente
            if let c = i.conversa, c.hasSuffix("@s.whatsapp.net") {
                let tel = c.split(separator: "@").first.map(String.init) ?? ""
                if tel.allSatisfy(\.isNumber), let u = URL(string: "whatsapp://send?phone=\(tel)"),
                   NSWorkspace.shared.open(u) { return }
            }
            // Restantes (contactos sem número visível e grupos): pesquisa pelo nome da conversa
            let nome = i.titulo.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F} "))
            if !nome.isEmpty, pesquisarNoWhatsApp(nome) { return }

        case "com.apple.mail":
            if let id = i.idMensagem,
               let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))),
               let u = URL(string: "message://\(enc)"), NSWorkspace.shared.open(u) { return }

        default: break
        }
        abrirApp()
    }

    /// Abre o WhatsApp com a pesquisa preenchida com o nome da conversa (a conversa fica em primeiro).
    /// Nunca carrega em Enter, para não haver risco de enviar nada.
    /// Precisa de autorização de Acessibilidade; sem ela devolve false.
    private static func pesquisarNoWhatsApp(_ nome: String) -> Bool {
        let opcoes = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opcoes),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: whatsapp) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard let app, app.isActive || app.activate() else { return }
                tecla(3, comando: true)            // ⌘F: vai para a pesquisa
                tecla(0, comando: true)            // ⌘A: apaga o que lá estiver
                escrever(nome)
            }
        }
        return true
    }

    private static func tecla(_ codigo: CGKeyCode, comando: Bool) {
        let fonte = CGEventSource(stateID: .hidSystemState)
        for desce in [true, false] {
            let e = CGEvent(keyboardEventSource: fonte, virtualKey: codigo, keyDown: desce)
            if comando { e?.flags = .maskCommand }
            e?.post(tap: .cghidEventTap)
        }
        usleep(120_000)
    }

    private static func escrever(_ texto: String) {
        let fonte = CGEventSource(stateID: .hidSystemState)
        for desce in [true, false] {
            let e = CGEvent(keyboardEventSource: fonte, virtualKey: 0, keyDown: desce)
            let u = Array(texto.utf16)
            e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            e?.post(tap: .cghidEventTap)
        }
    }
}
