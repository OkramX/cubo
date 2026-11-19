import AppKit
import CoreLocation
import Foundation

/// Coisas extra que o cubo mostra no relógio: treino do dia e forma (OkramX) e o tempo lá fora.
@MainActor
final class Extras: ObservableObject {
    static let shared = Extras()

    @Published var treino = ""        // ex.: "VO2max 4x3' 49min"
    @Published var forma = ""         // ex.: "Forma 29 Frescura +1"
    @Published var tempo = ""         // ex.: "18C  12/21"
    @Published var tempoIcone = ""    // sol, lua, pouco, nuvem, chuva, trovoada, neve, nevoeiro
    @Published var cidade = UserDefaults.standard.string(forKey: "tempoCidade") ?? "Lisboa"

    var aoMudar: (() -> Void)?
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in await Extras.shared.atualizar() }
        }
        Task { await atualizar() }
    }

    func atualizar() async {
        async let t: Void = atualizarTreino()
        async let w: Void = atualizarTempo()
        _ = await (t, w)
        aoMudar?()
    }

    // MARK: Treino (pela ligação MCP da OkramX: "OkramX --mcp")

    static func executavelOkramX() -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "pt.okramx.app") {
            let exe = url.appendingPathComponent("Contents/MacOS/OkramX").path
            if FileManager.default.isExecutableFile(atPath: exe) { return exe }
        }
        let fixo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OkramX/OkramX/build/OkramX.app/Contents/MacOS/OkramX").path
        return FileManager.default.isExecutableFile(atPath: fixo) ? fixo : nil
    }

    private func atualizarTreino() async {
        guard let exe = Self.executavelOkramX() else { treino = ""; forma = ""; return }
        let resultado = await Task.detached { () -> (Any?, Any?) in
            let mcp = ClienteMCP(executavel: exe)
            defer { mcp.terminar() }
            guard mcp.iniciar() else { return (nil, nil) }
            return (mcp.ferramenta("get_planned_workouts"), mcp.ferramenta("get_fitness_trend"))
        }.value

        let hoje: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
        }()
        if let planos = resultado.0 as? [[String: Any]] {
            let deHoje = planos.filter { ($0["start_date_local"] as? String ?? "").hasPrefix(hoje) }
            if let p = deHoje.first {
                let nome = p["name"] as? String ?? "Treino"
                let min = (p["moving_time"] as? Int ?? 0) / 60
                treino = min > 0 ? "\(nome) \(min)min" : nome
            } else {
                treino = "Hoje: descanso"
            }
        }
        if let dias = resultado.1 as? [[String: Any]], let d = dias.last,
           let ctl = d["ctl"] as? Double, let atl = d["atl"] as? Double {
            let tsb = Int((ctl - atl).rounded())
            forma = "Forma \(Int(ctl.rounded())) Frescura \(tsb >= 0 ? "+" : "")\(tsb)"
        }
    }

    // MARK: Tempo (Open-Meteo, sem chave)

    func mudarCidade(_ nome: String) async -> Bool {
        guard let p = try? await CLGeocoder().geocodeAddressString(nome).first, let loc = p.location else { return false }
        cidade = p.locality ?? nome
        UserDefaults.standard.set(cidade, forKey: "tempoCidade")
        UserDefaults.standard.set(loc.coordinate.latitude, forKey: "tempoLat")
        UserDefaults.standard.set(loc.coordinate.longitude, forKey: "tempoLon")
        await atualizarTempo()
        aoMudar?()
        return true
    }

    private func atualizarTempo() async {
        let d = UserDefaults.standard
        let lat = d.object(forKey: "tempoLat") as? Double ?? 38.72
        let lon = d.object(forKey: "tempoLon") as? Double ?? -9.14
        let s = String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f" +
                       "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min" +
                       "&timezone=auto&forecast_days=1", lat, lon)
        guard let url = URL(string: s),
              let (dados, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let atual = j["current"] as? [String: Any],
              let temp = atual["temperature_2m"] as? Double else { return }
        let codigo = atual["weather_code"] as? Int ?? 3
        let dia = (atual["is_day"] as? Int ?? 1) == 1
        var texto = "\(Int(temp.rounded()))C"
        if let dd = j["daily"] as? [String: Any],
           let mx = (dd["temperature_2m_max"] as? [Double])?.first,
           let mn = (dd["temperature_2m_min"] as? [Double])?.first {
            texto += "  \(Int(mn.rounded()))/\(Int(mx.rounded()))"
        }
        tempo = texto
        tempoIcone = Self.icone(codigo, dia: dia)
    }

    static func icone(_ c: Int, dia: Bool) -> String {
        switch c {
        case 0: return dia ? "sol" : "lua"
        case 1, 2: return dia ? "pouco" : "lua"
        case 45, 48: return "nevoeiro"
        case 51...67, 80...82: return "chuva"
        case 71...77, 85, 86: return "neve"
        case 95...99: return "trovoada"
        default: return "nuvem"
        }
    }
}

/// Cliente MCP mínimo por stdio (JSON-RPC, uma mensagem por linha).
final class ClienteMCP {
    private let processo = Process()
    private let entrada = Pipe(), saida = Pipe()
    private var resto = Data()
    private var proximoId = 1

    init(executavel: String) {
        processo.executableURL = URL(fileURLWithPath: executavel)
        processo.arguments = ["--mcp"]
        processo.standardInput = entrada
        processo.standardOutput = saida
        processo.standardError = FileHandle.nullDevice
    }

    func iniciar() -> Bool {
        do { try processo.run() } catch { return false }
        // segurança: se a OkramX não responder, fecha-a ao fim de 30 s (a leitura desbloqueia)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [processo] in
            if processo.isRunning { processo.terminate() }
        }
        let r = pedir("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:],
                                     "clientInfo": ["name": "cubo", "version": "1"]])
        guard r != nil else { return false }
        enviar(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return true
    }

    /// Chama uma ferramenta e devolve o JSON do texto da resposta.
    func ferramenta(_ nome: String) -> Any? {
        guard let r = pedir("tools/call", ["name": nome, "arguments": [:]]),
              let res = r["result"] as? [String: Any],
              let conteudo = res["content"] as? [[String: Any]],
              let texto = conteudo.first?["text"] as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(texto.utf8))
    }

    func terminar() { if processo.isRunning { processo.terminate() } }

    private func enviar(_ msg: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(0x0A)
        try? entrada.fileHandleForWriting.write(contentsOf: d)
    }

    private func pedir(_ metodo: String, _ params: [String: Any]) -> [String: Any]? {
        let id = proximoId; proximoId += 1
        enviar(["jsonrpc": "2.0", "id": id, "method": metodo, "params": params])
        let limite = Date().addingTimeInterval(20)
        while Date() < limite {
            while let i = resto.firstIndex(of: 0x0A) {
                let linha = resto[resto.startIndex..<i]
                resto.removeSubrange(resto.startIndex...i)
                if let j = try? JSONSerialization.jsonObject(with: linha) as? [String: Any],
                   j["id"] as? Int == id { return j }
            }
            let d = saida.fileHandleForReading.availableData   // bloqueia até haver dados
            if d.isEmpty { return nil }
            resto.append(d)
        }
        return nil
    }
}
