import Foundation

/// Lê e grava o mesmo config.json que o script Python usava, preservando chaves desconhecidas.
struct CuboConfig {
    static let pasta = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cubo", isDirectory: true)
    static let caminho = pasta.appendingPathComponent("config.json")

    static let padrao: [String: Any] = [
        "cubo_url": "http://192.168.1.25",
        "token": "troca-isto-por-um-codigo-teu",
        "intervalo_segundos": 2,
        "todas_as_apps": false,
        "apps": [
            "com.apple.mail": "Mail",
            "com.microsoft.outlook": "Outlook",
            "com.microsoft.teams2": "Teams",
            "com.apple.ical": "Calendario",
            "net.whatsapp.whatsapp": "WhatsApp",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.google.chrome": "Chrome",
            "com.hnc.discord": "Discord",
        ],
        "apps_ignoradas": [String](),
        "mostrar_titulo": true,
        "mostrar_subtitulo": false,
        "mostrar_texto": false,
        "codigos_verificacao": "esconder",
    ]

    var raw: [String: Any]

    static func carregar() -> CuboConfig {
        var cfg = padrao
        if let d = try? Data(contentsOf: caminho),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in j { cfg[k] = v }
        }
        return CuboConfig(raw: cfg)
    }

    func gravar() {
        try? FileManager.default.createDirectory(at: Self.pasta, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Self.caminho, options: .atomic)
        }
    }

    var cuboURL: String {
        get { raw["cubo_url"] as? String ?? "http://192.168.1.25" }
        set { raw["cubo_url"] = newValue }
    }
    var token: String {
        get { raw["token"] as? String ?? "" }
        set { raw["token"] = newValue }
    }
    var intervalo: Double { max(1, (raw["intervalo_segundos"] as? NSNumber)?.doubleValue ?? 2) }
    var todasAsApps: Bool {
        get { raw["todas_as_apps"] as? Bool ?? false }
        set { raw["todas_as_apps"] = newValue }
    }
    var apps: [String: String] {
        get { raw["apps"] as? [String: String] ?? [:] }
        set { raw["apps"] = newValue }
    }
    var appsIgnoradas: [String] { raw["apps_ignoradas"] as? [String] ?? [] }
    var mostrarTitulo: Bool {
        get { raw["mostrar_titulo"] as? Bool ?? true }
        set { raw["mostrar_titulo"] = newValue }
    }
    var mostrarSubtitulo: Bool {
        get { raw["mostrar_subtitulo"] as? Bool ?? false }
        set { raw["mostrar_subtitulo"] = newValue }
    }
    var mostrarTexto: Bool {
        get { raw["mostrar_texto"] as? Bool ?? false }
        set { raw["mostrar_texto"] = newValue }
    }
    var pessoasPrioritarias: [String] {
        get { raw["pessoas_prioritarias"] as? [String] ?? [] }
        set { raw["pessoas_prioritarias"] = newValue }
    }
    var pausa: Bool {
        get { raw["lembrete_pausa"] as? Bool ?? true }
        set { raw["lembrete_pausa"] = newValue }
    }
    var som: Bool {
        get { raw["som"] as? Bool ?? true }
        set { raw["som"] = newValue }
    }
    var respostas: Bool {
        get { raw["respostas_sugeridas"] as? Bool ?? true }
        set { raw["respostas_sugeridas"] = newValue }
    }
    var sobreMim: String {
        get { raw["sobre_mim"] as? String ?? "" }
        set { raw["sobre_mim"] = newValue }
    }
    var pessoasVip: [String] {
        get { raw["pessoas_vip"] as? [String] ?? [] }
        set { raw["pessoas_vip"] = newValue }
    }
    /// Concentração automática durante as reuniões do Calendário
    var reunioesAuto: Bool {
        get { raw["reunioes_auto"] as? Bool ?? true }
        set { raw["reunioes_auto"] = newValue }
    }
    var resumoManha: Bool {
        get { raw["resumo_manha"] as? Bool ?? true }
        set { raw["resumo_manha"] = newValue }
    }
    /// Minutos desde a meia-noite (ex.: 540 = 9h00)
    var resumoManhaMin: Int {
        get { (raw["resumo_manha_min"] as? NSNumber)?.intValue ?? 540 }
        set { raw["resumo_manha_min"] = newValue }
    }
    var fimDia: Bool {
        get { raw["fim_dia"] as? Bool ?? true }
        set { raw["fim_dia"] = newValue }
    }
    var fimDiaMin: Int {
        get { (raw["fim_dia_min"] as? NSNumber)?.intValue ?? 1080 }
        set { raw["fim_dia_min"] = newValue }
    }
    var lembreteTreino: Bool {
        get { raw["lembrete_treino"] as? Bool ?? true }
        set { raw["lembrete_treino"] = newValue }
    }
    var treinoMin: Int {
        get { (raw["treino_min"] as? NSNumber)?.intValue ?? 1110 }
        set { raw["treino_min"] = newValue }
    }
    var relatorioSemanal: Bool {
        get { raw["relatorio_semanal"] as? Bool ?? true }
        set { raw["relatorio_semanal"] = newValue }
    }
    /// Mascote a saltar no canto do ecrã
    var mascote: Bool {
        get { raw["mascote"] as? Bool ?? true }
        set { raw["mascote"] = newValue }
    }
    var mascoteMin: Int {
        get { (raw["mascote_min"] as? NSNumber)?.intValue ?? 5 }
        set { raw["mascote_min"] = newValue }
    }
    /// Resumos de grupos do WhatsApp: grupos escolhidos (jid → nome)
    var gruposResumo: [String: String] {
        get { raw["grupos_resumo"] as? [String: String] ?? [:] }
        set { raw["grupos_resumo"] = newValue }
    }
    /// Resumir quando a conversa acalma (X min sem mensagens e pelo menos N mensagens novas)
    var gruposAcalma: Bool {
        get { raw["grupos_acalma"] as? Bool ?? true }
        set { raw["grupos_acalma"] = newValue }
    }
    var gruposAcalmaMin: Int {
        get { (raw["grupos_acalma_min"] as? NSNumber)?.intValue ?? 10 }
        set { raw["grupos_acalma_min"] = newValue }
    }
    var gruposMinMensagens: Int {
        get { (raw["grupos_min_mensagens"] as? NSNumber)?.intValue ?? 5 }
        set { raw["grupos_min_mensagens"] = newValue }
    }
    /// Resumir também a horas certas (minutos desde a meia-noite)
    var gruposHoras: Bool {
        get { raw["grupos_horas"] as? Bool ?? false }
        set { raw["grupos_horas"] = newValue }
    }
    var gruposHorasLista: [Int] {
        get { (raw["grupos_horas_lista"] as? [NSNumber])?.map(\.intValue) ?? [780, 1140] }
        set { raw["grupos_horas_lista"] = newValue }
    }
    var codigos: String {
        get { raw["codigos_verificacao"] as? String ?? "esconder" }
        set { raw["codigos_verificacao"] = newValue }
    }

    /// Nome a mostrar para uma app, ou nil se a app não está escolhida.
    func nome(para bundle: String) -> String? {
        let b = bundle.lowercased()
        if appsIgnoradas.contains(where: { $0.lowercased() == b }) { return nil }
        if let n = apps.first(where: { $0.key.lowercased() == b })?.value { return n }
        if todasAsApps { return Self.nomeAmigavel(bundle) }
        return nil
    }

    static func nomeAmigavel(_ bundle: String) -> String {
        let p = bundle.split(separator: ".").last.map(String.init) ?? "App"
        return p.prefix(1).uppercased() + p.dropFirst()
    }
}
