import Foundation

struct EstadoCubo: Decodable {
    let versao: String
    let ip: String
    let rssi: Int
    let nao_lidas: Int
    let hora_ok: Bool
    let uptime_s: Int
    let cabo: Bool?     // a resposta veio pelo cabo USB
    let wifi: Bool?
}

/// Comunicação com o cubo: pelo cabo USB quando está ligado ao Mac, senão por Wi-Fi (HTTP).
struct CubeClient {
    let base: String
    let token: String
    /// Sessão própria (não a URLSession.shared): a procura na rede usa uma sessão temporária
    /// que é deitada fora no fim, senão a cache de ligações do macOS cresce sem parar e
    /// a app fica a gastar 100% de CPU quando o cubo está desligado.
    var sessao: URLSession = CubeClient.sessaoNormal

    static let sessaoNormal: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 2
        c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()

    private func pedido(_ caminho: String, metodo: String = "POST", corpo: [String: Any]? = nil,
                        timeout: TimeInterval = 4) -> URLRequest? {
        if Edicao.semCubo { return nil }
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

    /// Tenta primeiro o cabo USB; "/brilho?valor=5" passa a {"valor":5}.
    private func peloCabo(_ caminho: String, corpo: [String: Any]?) async -> (Int, Data)? {
        guard !Edicao.semCubo, !CaboUSB.portas().isEmpty else { return nil }
        var c = corpo ?? [:]
        var so = caminho
        if let comp = URLComponents(string: caminho) {
            so = comp.path
            for q in comp.queryItems ?? [] { c[q.name] = Int(q.value ?? "") ?? q.value ?? "" }
        }
        return await CaboUSB.shared.pedido(so, corpo: c.isEmpty && corpo == nil ? nil : c)
    }

    @discardableResult
    func enviar(_ caminho: String, corpo: [String: Any]? = nil) async -> Int {
        if let r = await peloCabo(caminho, corpo: corpo ?? [:]) { return r.0 }
        guard let r = pedido(caminho, corpo: corpo) else { return -1 }
        do {
            let (_, resp) = try await sessao.data(for: r)
            return (resp as? HTTPURLResponse)?.statusCode ?? -1
        } catch { return -1 }
    }

    func estado(timeout: TimeInterval = 4, porCabo: Bool = true) async -> EstadoCubo? {
        if porCabo, let (c, d) = await peloCabo("/estado", corpo: nil), c == 200,
           let e = try? JSONDecoder().decode(EstadoCubo.self, from: d) { return e }
        guard let r = pedido("/estado", metodo: "GET", timeout: timeout),
              let (d, _) = try? await sessao.data(for: r) else { return nil }
        return try? JSONDecoder().decode(EstadoCubo.self, from: d)
    }

    /// Envia uma notificação com até 5 tentativas. Devolve false se o token for recusado ou o cubo não responder.
    func notificar(_ dados: [String: String], vip: Bool = false) async -> Bool {
        if Edicao.semCubo { Edicao.avisoMac(dados); return true }
        var corpo: [String: Any] = dados
        if vip { corpo["vip"] = true }
        for tentativa in 1...5 {
            let c = await enviar("/notify", corpo: corpo)
            if c == 200 { return true }
            if c == 401 { return false }
            try? await Task.sleep(nanoseconds: UInt64(min(2 * tentativa, 8)) * 1_000_000_000)
        }
        return false
    }

    func brilho(_ v: Int) async { await enviar("/brilho?valor=\(v)") }

    struct Redes: Decodable { let redes: [String]; let atual: String; let max: Int }

    private func pedirRedes(_ r: URLRequest?) async -> Redes? {
        guard let r, let (d, resp) = try? await sessao.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Redes.self, from: d)
    }
    private func redesPeloCabo(_ caminho: String, _ corpo: [String: Any]?) async -> Redes? {
        guard let (c, d) = await peloCabo(caminho, corpo: corpo), c == 200 else { return nil }
        return try? JSONDecoder().decode(Redes.self, from: d)
    }
    func redes() async -> Redes? {
        if let r = await redesPeloCabo("/redes", nil) { return r }
        return await pedirRedes(pedido("/redes", metodo: "GET"))
    }
    func adicionarRede(_ ssid: String, _ senha: String) async -> Redes? {
        if let r = await redesPeloCabo("/redes", ["ssid": ssid, "senha": senha]) { return r }
        return await pedirRedes(pedido("/redes", corpo: ["ssid": ssid, "senha": senha]))
    }
    func apagarRede(_ ssid: String) async -> Redes? {
        if let r = await redesPeloCabo("/redes/apagar", ["ssid": ssid]) { return r }
        return await pedirRedes(pedido("/redes/apagar", corpo: ["ssid": ssid]))
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
