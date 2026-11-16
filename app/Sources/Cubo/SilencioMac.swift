import Foundation

/// Liga/desliga o "Não incomodar" do Mac através de dois atalhos da app Atalhos
/// (o macOS não deixa outras apps mudar o modo de foco diretamente),
/// e lê o estado atual dos ficheiros do próprio macOS.
enum SilencioMac {
    static let atalhoLigar = "Cubo Silêncio Ligar"
    static let atalhoDesligar = "Cubo Silêncio Desligar"

    private static let pasta = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB")

    /// Nome do modo de foco ativo (ex.: "Não incomodar"), ou nil se nenhum estiver ligado.
    static func modoAtivo() -> String? {
        guard let d = try? Data(contentsOf: pasta.appendingPathComponent("Assertions.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let dados = (j["data"] as? [[String: Any]])?.first,
              let ativos = dados["storeAssertionRecords"] as? [[String: Any]], !ativos.isEmpty
        else { return nil }
        let det = (ativos.first?["assertionDetails"] as? [String: Any]) ?? [:]
        let id = det["assertionDetailsModeIdentifier"] as? String ?? ""
        return nomeDoModo(id) ?? "Não incomodar"
    }

    private static func nomeDoModo(_ id: String) -> String? {
        if id == "com.apple.donotdisturb.mode.default" { return "Não incomodar" }
        guard let d = try? Data(contentsOf: pasta.appendingPathComponent("ModeConfigurations.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let dados = (j["data"] as? [[String: Any]])?.first,
              let modos = dados["modeConfigurations"] as? [String: Any],
              let m = (modos[id] as? [String: Any])?["mode"] as? [String: Any]
        else { return nil }
        return m["name"] as? String
    }

    /// Os dois atalhos existem na app Atalhos?
    static func atalhosProntos() -> Bool {
        let nomes = Set(correr(["list"]).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        })
        return nomes.contains(atalhoLigar.precomposedStringWithCanonicalMapping)
            && nomes.contains(atalhoDesligar.precomposedStringWithCanonicalMapping)
    }

    static func definir(_ ligado: Bool) {
        _ = correr(["run", ligado ? atalhoLigar : atalhoDesligar])
    }

    @discardableResult
    private static func correr(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = saida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
}
