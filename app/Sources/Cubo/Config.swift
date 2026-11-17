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
