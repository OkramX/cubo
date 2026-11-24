import Foundation
import UserNotifications

/// Edição da app. A edição «sem cubo» (compilada com -DSEM_CUBO, ver construir-sem-cubo.sh)
/// não fala com o cubo físico nem com a OkramX: os avisos do assistente (bom dia, pausa,
/// fim da reunião, relatório da semana…) aparecem como notificações normais do Mac.
enum Edicao {
    #if SEM_CUBO
    static let semCubo = true
    #else
    static let semCubo = false
    #endif

    /// Mostra um aviso do assistente no Mac (só na edição sem cubo).
    static func avisoMac(_ dados: [String: String]) {
        let centro = UNUserNotificationCenter.current()
        centro.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = dados["titulo"] ?? "Cubo"
            c.body = dados["texto"] ?? ""
            centro.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
