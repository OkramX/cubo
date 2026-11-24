import EventKit
import AppKit
import Foundation
import Network
import ServiceManagement

struct ItemEntrada: Codable, Identifiable, Hashable {
    let id: String
    let bundle: String
    let app: String
    let titulo: String
    let subtitulo: String
    let texto: String
    let quando: Date
    var visto: Bool
    var conversa: String? = nil
    var link: String? = nil
    var idMensagem: String? = nil
}

private struct Guardado: Codable {
    var ultimo: Int64
    var itens: [ItemEntrada]
}

@MainActor
final class AppState: ObservableObject {
    @Published var itens: [ItemEntrada] = []
    @Published var config = CuboConfig.carregar()
    @Published var erroBD: String?
    @Published var estadoCubo: EstadoCubo?
    @Published var cuboOnline = false
    @Published var ultimoEnvioFalhou = false
    @Published var scriptAntigoAtivo = false
    @Published var appsConhecidas: [(String, Int)] = []

    // Modo Concentração
    @Published var focoAte: Date? = UserDefaults.standard.object(forKey: "focoAte") as? Date {
        didSet { UserDefaults.standard.set(focoAte, forKey: "focoAte"); aoMudarFoco?() }
    }
    private(set) var focoDesde: Date? = UserDefaults.standard.object(forKey: "focoDesde") as? Date {
        didSet { UserDefaults.standard.set(focoDesde, forKey: "focoDesde") }
    }
    var aoMudarFoco: (() -> Void)?
    /// Abre a janela principal (definido pela interface).
    var abrirJanela: (() -> Void)?

    // Silêncio do Mac (Não incomodar), controlado por atalhos
    @Published var modoFocoMac: String?
    @Published var atalhosSilencioProntos = false
    @Published var aMudarSilencio = false

    // Encontrar o cubo em qualquer rede
    @Published var aProcurarCubo = false
    private var ultimaProcura = Date.distantPast
    private let monitorRede = NWPathMonitor()

    private let bd = NotificationDB()
    private var ultimo: Int64 = -1
    private var timerBD: Timer?
    private var timerCubo: Timer?
    private var proximaTentativaBD = Date.distantPast
    private let ficheiro = CuboConfig.pasta.appendingPathComponent("entrada.json")
    private static let maxItens = 500

    var porVer: [ItemEntrada] { itens.filter { !$0.visto } }
    var cubo: CubeClient { CubeClient(base: config.cuboURL, token: config.token) }

    init() {
        carregarEntrada()
        verificarScriptAntigo()
        timerBD = Timer.scheduledTimer(withTimeInterval: config.intervalo, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.vigiar() }
        }
        timerCubo = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.verificarFimDoFoco()
                self?.verificarReunioes()
                self?.lerSilencioMac()
                await self?.atualizarEstadoCubo()
                self?.verificarScriptAntigo()
            }
        }
        vigiar()
        lerSilencioMac()
        verificarAtalhosSilencio()
        Task { await atualizarEstadoCubo() }
        // Quando o Mac muda de rede, volta a procurar o cubo
        monitorRede.pathUpdateHandler = { [weak self] caminho in
            guard caminho.status == .satisfied else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.ultimaProcura = .distantPast
                await self?.atualizarEstadoCubo()
            }
        }
        monitorRede.start(queue: .main)
    }

    // MARK: Entrada guardada em disco

    private func carregarEntrada() {
        guard let d = try? Data(contentsOf: ficheiro),
              let g = try? JSONDecoder().decode(Guardado.self, from: d) else { return }
        itens = g.itens
        ultimo = g.ultimo
    }

    private func guardarEntrada() {
        if itens.count > Self.maxItens {
            // apaga primeiro os mais antigos já vistos
            let excesso = itens.count - Self.maxItens
            let vistosAntigos = itens.enumerated().filter { $0.element.visto }
                .sorted { $0.element.quando < $1.element.quando }.prefix(excesso).map(\.offset)
            for i in vistosAntigos.sorted(by: >) { itens.remove(at: i) }
        }
        try? FileManager.default.createDirectory(at: CuboConfig.pasta, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Guardado(ultimo: ultimo, itens: itens)) {
            try? d.write(to: ficheiro, options: .atomic)
        }
    }

    // MARK: Vigiar a base de dados

    func vigiar() {
        do {
            if !bd.aberta {
                guard Date() >= proximaTentativaBD else { return }
                try bd.abrir()
                erroBD = nil
                appsConhecidas = bd.appsComNotificacoes()
                if ultimo < 0 {
                    // primeira vez: traz as notificações das últimas 24 h, sem as enviar para o cubo
                    ultimo = try bd.maxRecID()
                    let antigos = try bd.registos(depoisDe: 0, desde: Date().addingTimeInterval(-86400))
                    for r in antigos { if let i = item(de: r) { itens.insert(i, at: 0) } }
                    itens.sort { $0.quando > $1.quando }
                    guardarEntrada()
                }
            }
            let atual = try bd.maxRecID()
            if atual < ultimo { ultimo = atual }   // o macOS limpou a base de dados
            let novos = try bd.registos(depoisDe: ultimo)
            guard !novos.isEmpty else { return }
            var tocar = false, tocarVip = false
            for r in novos {
                ultimo = max(ultimo, r.recID)
                guard let i = item(de: r) else { continue }
                itens.insert(i, at: 0)
                enviarParaCubo(i)
                Respostas.shared.considerar(i)
                if vip(i) { tocarVip = true } else if !emFoco || prioritaria(i) { tocar = true }
            }
            if tocarVip && config.som { Som.tocarVip() } else if tocar && config.som { Som.tocar() }
            appsConhecidas = bd.appsComNotificacoes()
            guardarEntrada()
        } catch {
            bd.fechar()
            erroBD = "\(error)"
            proximaTentativaBD = Date().addingTimeInterval(15)
        }
    }

    private func item(de r: NotificationDB.Registo) -> ItemEntrada? {
        if r.bundle == Bundle.main.bundleIdentifier { return nil }   // os avisos da própria Cubo
        guard let nome = config.nome(para: r.bundle),
              let info = NotificationDB.decodificar(r.data) else { return nil }
        if info.titulo.isEmpty && info.texto.isEmpty && info.subtitulo.isEmpty { return nil }
        return ItemEntrada(id: "\(r.recID)-\(Int(r.quando.timeIntervalSinceReferenceDate))",
                           bundle: r.bundle, app: nome, titulo: info.titulo,
                           subtitulo: info.subtitulo, texto: info.texto, quando: r.quando, visto: false,
                           conversa: info.conversa, link: info.link, idMensagem: info.idMensagem)
    }

    private func enviarParaCubo(_ i: ItemEntrada) {
        guard !Edicao.semCubo, !scriptAntigoAtivo, let dados = Preparar.paraCubo(i, cfg: config) else { return }
        if emFoco && !prioritaria(i) { return }   // fica só na Entrada
        let c = cubo, ehVip = vip(i)
        Task {
            let ok = await c.notificar(dados, vip: ehVip)
            self.ultimoEnvioFalhou = !ok
        }
    }

    // MARK: Ações

    func marcarVisto(_ i: ItemEntrada) {
        guard let k = itens.firstIndex(where: { $0.id == i.id }) else { return }
        itens[k].visto = true
        guardarEntrada()
        if porVer.isEmpty { Task { await cubo.limpar() } }
    }

    func marcarTudoVisto() {
        for k in itens.indices { itens[k].visto = true }
        guardarEntrada()
        Task { await cubo.limpar() }
    }

    func apagarVistos() {
        itens.removeAll { $0.visto }
        guardarEntrada()
    }

    /// Clicar numa notificação: marca como vista e abre o sítio certo na app de origem.
    func abrirNotificacao(_ i: ItemEntrada) {
        if !i.visto { marcarVisto(i) }
        AbrirOrigem.abrir(i) { self.abrirApp(i) }
    }

    func abrirApp(_ i: ItemEntrada) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: i.bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: Silêncio do Mac

    var macEmSilencio: Bool { modoFocoMac != nil }

    func lerSilencioMac() { modoFocoMac = SilencioMac.modoAtivo() }

    func verificarAtalhosSilencio() {
        Task.detached {
            let ok = SilencioMac.atalhosProntos()
            await MainActor.run { self.atalhosSilencioProntos = ok }
        }
    }

    func definirSilencioMac(_ ligado: Bool) {
        aMudarSilencio = true
        Task.detached {
            SilencioMac.definir(ligado)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                self.lerSilencioMac()
                self.aMudarSilencio = false
            }
        }
    }

    // MARK: Concentração

    var emFoco: Bool { (focoAte ?? .distantPast) > Date() }

    func vip(_ i: ItemEntrada) -> Bool {
        let quem = Preparar.ascii(i.titulo + " " + i.subtitulo).lowercased()
        return config.pessoasVip.contains { p in
            let n = Preparar.ascii(p).lowercased()
            return !n.isEmpty && quem.contains(n)
        }
    }

    func prioritaria(_ i: ItemEntrada) -> Bool {
        if vip(i) { return true }
        let quem = Preparar.ascii(i.titulo + " " + i.subtitulo).lowercased()
        return config.pessoasPrioritarias.contains { p in
            let n = Preparar.ascii(p).lowercased()
            return !n.isEmpty && quem.contains(n)
        }
    }

    /// Nome da reunião quando a Concentração foi ligada automaticamente por uma reunião
    @Published var focoReuniao: String? = UserDefaults.standard.string(forKey: "focoReuniao") {
        didSet { UserDefaults.standard.set(focoReuniao, forKey: "focoReuniao") }
    }
    /// Eventos de hoje (vem da Agenda)
    var eventosAgora: () -> [EKEvent] = { [] }
    private var ultimaReuniaoAuto = UserDefaults.standard.string(forKey: "ultimaReuniaoAuto") ?? ""

    /// Liga a Concentração quando começa uma reunião (se a opção estiver ligada).
    func verificarReunioes() {
        guard config.reunioesAuto, !emFoco else { return }
        let agora = Date()
        guard let ev = eventosAgora().first(where: {
            !$0.isAllDay && $0.startDate <= agora && $0.endDate > agora
                && $0.endDate.timeIntervalSince($0.startDate) <= 4 * 3600
                && $0.availability != .free
        }) else { return }
        let id = "\(ev.eventIdentifier ?? ev.title ?? "")|\(Int(ev.startDate.timeIntervalSince1970))"
        guard id != ultimaReuniaoAuto else { return }   // terminaste-a à mão: não volta a ligar
        ultimaReuniaoAuto = id
        UserDefaults.standard.set(id, forKey: "ultimaReuniaoAuto")
        focoDesde = Date()
        focoReuniao = ev.title ?? "Reunião"
        focoAte = ev.endDate
    }

    /// Olhos do cubo: 1 contentes (tudo visto), 2 com sono (noite), 3 preocupados (muito por ver)
    var humorCubo: Int {
        let h = Calendar.current.component(.hour, from: Date())
        if h >= 23 || h < 7 { return 2 }
        if porVer.count >= 10 { return 3 }
        if porVer.isEmpty { return 1 }
        return 0
    }

    /// Sessões de Concentração terminadas (para o relatório da semana)
    static func registarFoco(_ desde: Date, _ ate: Date) {
        var l = UserDefaults.standard.array(forKey: "registoFoco") as? [[Double]] ?? []
        l.append([desde.timeIntervalSince1970, ate.timeIntervalSince1970])
        l = l.filter { $0[1] > Date().timeIntervalSince1970 - 60 * 86400 }
        UserDefaults.standard.set(l, forKey: "registoFoco")
    }

    func comecarFoco(minutos: Int) {
        focoReuniao = nil
        if !emFoco { focoDesde = Date() }
        focoAte = Date().addingTimeInterval(TimeInterval(minutos * 60))
    }

    func alternarFoco() {
        if emFoco { terminarFoco() } else { comecarFoco(minutos: 60) }
    }

    func terminarFoco() {
        let desde = focoDesde, reuniao = focoReuniao
        focoAte = nil
        focoDesde = nil
        focoReuniao = nil
        guard let desde else { return }
        Self.registarFoco(desde, Date())
        let perdidas = itens.filter { !$0.visto && $0.quando >= desde && !prioritaria($0) }
        guard !scriptAntigoAtivo else { return }
        let c = cubo
        if reuniao != nil {
            // No fim da reunião: o que entrou entretanto
            var quem: [String] = []
            for i in perdidas where !i.titulo.isEmpty && !quem.contains(i.titulo) { quem.append(i.titulo) }
            let texto = perdidas.isEmpty ? "Nada de novo. Bom trabalho!"
                : "\(perdidas.count) por ver: " + quem.prefix(3).joined(separator: ", ") + (quem.count > 3 ? "..." : "")
            Task { await c.notificar(["app": "Cubo", "titulo": "Fim da reuniao", "texto": Preparar.ascii(texto)]) }
            return
        }
        guard !perdidas.isEmpty else { return }
        Task {
            await c.notificar(["app": "Cubo", "titulo": "Fim do foco",
                               "texto": "\(perdidas.count) \(perdidas.count == 1 ? "notificacao" : "notificacoes") por ver"])
        }
    }

    private func verificarFimDoFoco() {
        if let f = focoAte, f <= Date() { terminarFoco() }
    }

    func adicionarPessoa(_ nome: String) {
        let n = nome.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !config.pessoasPrioritarias.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame })
        else { return }
        config.pessoasPrioritarias.append(n)
        gravarConfig()
    }

    func removerPessoa(_ nome: String) {
        config.pessoasPrioritarias.removeAll { $0 == nome }
        gravarConfig()
    }

    /// Remetentes mais frequentes na Entrada, para sugerir como prioritários.
    var remetentesFrequentes: [String] {
        var c: [String: Int] = [:]
        for i in itens where !i.titulo.isEmpty { c[i.titulo, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.map(\.key)
            .filter { r in !config.pessoasPrioritarias.contains { $0.caseInsensitiveCompare(r) == .orderedSame } }
            .prefix(8).map { $0 }
    }

    // MARK: Cubo

    func atualizarEstadoCubo() async {
        if Edicao.semCubo { return }
        var e = await cubo.estado()
        if e == nil, Date().timeIntervalSince(ultimaProcura) > 60 {
            e = await procurarCubo()
        }
        estadoCubo = e
        cuboOnline = e != nil
    }

    /// Procura o cubo pelo nome cubo.local e, se falhar, em todos os endereços da rede atual.
    /// Quando o encontra, guarda o endereço novo.
    func procurarCubo() async -> EstadoCubo? {
        ultimaProcura = Date()
        aProcurarCubo = true
        defer { aProcurarCubo = false }
        let token = config.token
        if let e = await CubeClient(base: "http://cubo.local", token: token).estado(timeout: 3, porCabo: false) {
            guardarEnderecoCubo(e.ip)
            return e
        }
        for prefixo in Self.redesLocais() {
            let achado: EstadoCubo? = await withTaskGroup(of: EstadoCubo?.self) { g in
                var proximo = 1
                func lancar() {
                    guard proximo <= 254 else { return }
                    let ip = "\(prefixo).\(proximo)"
                    proximo += 1
                    g.addTask { await CubeClient(base: "http://\(ip)", token: token).estado(timeout: 1.2, porCabo: false) }
                }
                for _ in 0..<48 { lancar() }
                while let r = await g.next() {
                    if let r { g.cancelAll(); return r }
                    lancar()
                }
                return nil
            }
            if let e = achado {
                guardarEnderecoCubo(e.ip)
                return e
            }
        }
        return nil
    }

    private func guardarEnderecoCubo(_ ip: String) {
        let url = "http://\(ip)"
        guard !ip.isEmpty, config.cuboURL != url else { return }
        config.cuboURL = url
        config.gravar()
    }

    /// Prefixos /24 das redes IPv4 privadas a que o Mac está ligado (ex.: "192.168.1").
    static func redesLocais() -> [String] {
        var out: [String] = []
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primeiro = lista else { return [] }
        defer { freeifaddrs(lista) }
        for p in sequence(first: primeiro, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  (Int32(i.ifa_flags) & IFF_UP) != 0, (Int32(i.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let partes = ip.split(separator: ".")
            guard partes.count == 4 else { continue }
            let privado = ip.hasPrefix("192.168.") || ip.hasPrefix("10.")
                || (partes[0] == "172" && (16...31).contains(Int(partes[1]) ?? 0))
            if privado {
                let pref = partes.prefix(3).joined(separator: ".")
                if !out.contains(pref) { out.append(pref) }
            }
        }
        return out
    }

    func gravarConfig() {
        config.gravar()
        Task { await atualizarEstadoCubo() }
    }

    func appEscolhida(_ bundle: String) -> Bool {
        config.apps.keys.contains { $0.lowercased() == bundle.lowercased() }
    }

    func escolherApp(_ bundle: String, _ sim: Bool) {
        var a = config.apps
        if sim {
            a[bundle] = Self.nomeDaApp(bundle)
        } else {
            for k in a.keys where k.lowercased() == bundle.lowercased() { a.removeValue(forKey: k) }
        }
        config.apps = a
        gravarConfig()
    }

    static func nomeDaApp(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let n = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            // nomes iguais aos do firmware, para o cubo encontrar o ícone
            switch bundle.lowercased() {
            case "com.apple.ical": return "Calendario"
            case "com.apple.mobilesms": return "Mensagens"
            default: return Preparar.ascii(n)
            }
        }
        return CuboConfig.nomeAmigavel(bundle)
    }

    func enviarTeste() {
        Task {
            let ok = await cubo.notificar(["app": "Teste", "titulo": "Ola", "texto": "Enviado pela app Cubo"])
            ultimoEnvioFalhou = !ok
        }
    }

    // MARK: Script antigo (Python + launchd)

    static let rotuloScript = "pt.cubo.notificacoes"

    func verificarScriptAntigo() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(Self.rotuloScript)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); scriptAntigoAtivo = p.terminationStatus == 0 }
        catch { scriptAntigoAtivo = false }
    }

    // MARK: Abrir ao iniciar sessão

    var abrirNoArranque: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

// MARK: - Ícones das apps (cache)

enum Icones {
    private static var cache: [String: NSImage] = [:]

    @MainActor static func de(_ bundle: String) -> NSImage {
        if let i = cache[bundle] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundle] = img
        return img
    }
}
