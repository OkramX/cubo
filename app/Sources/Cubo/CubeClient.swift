import Foundation

struct EstadoCubo: Decodable {
    let versao: String
    let ip: String
    let rssi: Int
    let nao_lidas: Int
    let hora_ok: Bool
    let uptime_s: Int
}

/// Comunicação HTTP com o cubo.
struct CubeClient {
    let base: String
    let token: String

    private func pedido(_ caminho: String, metodo: String = "POST", corpo: [String: Any]? = nil,
                        timeout: TimeInterval = 4) -> URLRequest? {
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + caminho)
        else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = metodo
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(token, forHTTPHeaderField: "X-Token")
        if metodo == "POST" {
            r.httpBody = try? JSONSerialization.data(withJSONObject: corpo ?? [:])
        }
        return r
    }

    @discardableResult
    func enviar(_ caminho: String, corpo: [String: Any]? = nil) async -> Int {
        guard let r = pedido(caminho, corpo: corpo) else { return -1 }
        do {
            let (_, resp) = try await URLSession.shared.data(for: r)
            return (resp as? HTTPURLResponse)?.statusCode ?? -1
        } catch { return -1 }
    }

    func estado(timeout: TimeInterval = 4) async -> EstadoCubo? {
        guard let r = pedido("/estado", metodo: "GET", timeout: timeout),
              let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return try? JSONDecoder().decode(EstadoCubo.self, from: d)
    }

    /// Envia uma notificação com até 5 tentativas. Devolve false se o token for recusado ou o cubo não responder.
    func notificar(_ dados: [String: String]) async -> Bool {
        for tentativa in 1...5 {
            let c = await enviar("/notify", corpo: dados)
            if c == 200 { return true }
            if c == 401 { return false }
            try? await Task.sleep(nanoseconds: UInt64(min(2 * tentativa, 8)) * 1_000_000_000)
        }
        return false
    }

    func brilho(_ v: Int) async { await enviar("/brilho?valor=\(v)") }

    struct Redes: Decodable { let redes: [String]; let atual: String; let max: Int }

    private func pedirRedes(_ r: URLRequest?) async -> Redes? {
        guard let r, let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Redes.self, from: d)
    }
    func redes() async -> Redes? { await pedirRedes(pedido("/redes", metodo: "GET")) }
    func adicionarRede(_ ssid: String, _ senha: String) async -> Redes? {
        await pedirRedes(pedido("/redes", corpo: ["ssid": ssid, "senha": senha]))
    }
    func apagarRede(_ ssid: String) async -> Redes? {
        await pedirRedes(pedido("/redes/apagar", corpo: ["ssid": ssid]))
    }
    func limpar() async { await enviar("/limpar") }
}

// MARK: - Preparação do que vai para o ecrã (igual ao script Python)

enum Preparar {
    private static let reNum = try! NSRegularExpression(pattern: "(?<!\\d)\\d{4,8}(?!\\d)")
    private static let rePal = try! NSRegularExpression(
        pattern: "c[oó]digo|code|verifica|autentica|otp|\\bpin\\b|2fa|senha|palavra-passe|password",
        options: [.caseInsensitive])

    static func ascii(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "€", with: "EUR")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "pt_PT"))
        let so = String(t.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        return so.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func pareceCodigo(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return reNum.firstMatch(in: s, range: r) != nil && rePal.firstMatch(in: s, range: r) != nil
    }

    static func paraCubo(_ item: ItemEntrada, cfg: CuboConfig) -> [String: String]? {
        var titulo = cfg.mostrarTitulo ? item.titulo : ""
        var partes: [String] = []
        if cfg.mostrarSubtitulo, !item.subtitulo.isEmpty { partes.append(item.subtitulo) }
        if cfg.mostrarTexto, !item.texto.isEmpty { partes.append(item.texto) }
        var texto = partes.joined(separator: " - ")
        if pareceCodigo([item.titulo, item.subtitulo, item.texto].joined(separator: " ")) {
            switch cfg.codigos {
            case "ignorar": return nil
            case "esconder":
                titulo = reNum.stringByReplacingMatches(in: titulo, range: NSRange(titulo.startIndex..., in: titulo),
                                                       withTemplate: "****")
                texto = "(codigo de verificacao oculto)"
            default: break
            }
        }
        return ["app": ascii(item.app), "titulo": ascii(titulo), "texto": ascii(texto)]
    }
}
