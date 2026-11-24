import AppKit
import SwiftUI

@main
struct CuboApp: App {
    @NSApplicationDelegateAdaptor(Delegado.self) private var delegado

    var body: some Scene {
        Window("Cubo", id: "principal") {
            JanelaPrincipal().environmentObject(delegado.estado).environmentObject(delegado.agenda)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 900, height: 620)
        .defaultLaunchBehavior(.suppressed)
    }
}

extension Delegado {
    func ligar() {
        let e = estado, a = agenda
        Respostas.shared.estado = e
        a.cubo = { e.cubo }
        a.focoAte = { e.focoAte }
        a.focoDesde = { e.focoDesde }
        a.focoNome = { e.focoReuniao }
        a.humor = { e.humorCubo }
        a.fimDia = { e.config.fimDia ? e.config.fimDiaMin : nil }
        e.eventosAgora = { a.eventos }
        Assistente.shared.ligar(estado: e, agenda: a)
        Extras.shared.aoMudar = { a.enviarResumo() }
        Pausa.shared.podeAvisar = { e.config.pausa && !e.emFoco }
        Pausa.shared.enviar = { dados in let c = e.cubo; Task { await c.notificar(dados) } }
        e.aoMudarFoco = { a.enviarResumo() }
        AtalhosGlobais.registar(abrir: { e.abrirJanela?() }, foco: { e.alternarFoco() })
        a.enviarResumo()
    }
}

// MARK: - Painel da barra de menus

struct MenuView: View {
    @EnvironmentObject var estado: AppState
    @EnvironmentObject var agenda: Agenda
    @Environment(\.openWindow) private var abrirJanela
    /// Altura máxima da parte do meio (o resto desliza); vem do tamanho do ecrã
    var limiteMeio: CGFloat = .infinity
    @State private var alturaMeio: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResumoDia()
            ScrollView(.vertical) {
                meio
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { alturaMeio = $0 }
            }
            .scrollIndicators(alturaMeio > limiteMeio ? .visible : .never)
            .frame(height: min(alturaMeio, limiteMeio))

            Divider()
            HStack {
                Button {
                    estado.abrirJanela?()
                } label: { Label("Abrir Cubo", systemImage: "macwindow") }
                Spacer()
                Button("Sair") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 360)
    }

    private var meio: some View {
        VStack(alignment: .leading, spacing: 10) {
            PainelAssistente()
            ControloFoco()
            ControloSilencioMac()
            PainelRespostas()
            HStack {
                EstadoCuboPill()
                Spacer()
                if !estado.porVer.isEmpty {
                    Button("Tudo visto") { estado.marcarTudoVisto() }
                        .buttonStyle(.link)
                }
            }

            if let e = estado.erroBD {
                AvisoAcesso(detalhe: e)
            }

            if estado.porVer.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                    Text("Está tudo visto").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                VStack(spacing: 2) {
                    ForEach(estado.porVer.prefix(6)) { i in
                        LinhaItem(item: i, compacta: true)
                    }
                }
                if estado.porVer.count > 6 {
                    Text("e mais \(estado.porVer.count - 6)…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 336, alignment: .leading)
    }
}

// MARK: - Janela principal

enum Separador: String, CaseIterable, Identifiable {
    case hoje = "Hoje", entrada = "Entrada", semana = "Semana", cubo = "Cubo"
    var id: String { rawValue }
    var icone: String {
        switch self { case .hoje: "sun.max"; case .entrada: "tray.full"; case .semana: "chart.bar"; case .cubo: "cube" }
    }
}

struct JanelaPrincipal: View {
    @EnvironmentObject var estado: AppState
    @EnvironmentObject var agenda: Agenda
    @StateObject private var separador = Caixa<Separador?>(.hoje)

    var body: some View {
        NavigationSplitView {
            List(Separador.allCases, selection: $separador.v) { s in
                Label(s.rawValue, systemImage: s.icone)
                    .badge(s == .entrada ? estado.porVer.count : s == .hoje ? agenda.tarefasHoje.count : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(170)
            .safeAreaInset(edge: .bottom) {
                EstadoCuboPill().padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch separador.v ?? .hoje {
            case .hoje: HojeView()
            case .entrada: EntradaView()
            case .semana: SemanaView()
            case .cubo: CuboView()
            }
        }
        .background {
            // ⌘1 / ⌘2 / ⌘3 mudam de separador
            ForEach(Array(Separador.allCases.enumerated()), id: \.offset) { k, s in
                Button("") { separador.v = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(k + 1)")), modifiers: .command)
                    .hidden()
            }
        }
    }
}

// MARK: - Componentes partilhados

struct EstadoCuboPill: View {
    @EnvironmentObject var estado: AppState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(estado.cuboOnline ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(estado.cuboOnline ? (estado.estadoCubo?.cabo == true ? "Cubo ligado pelo cabo" : "Cubo ligado") : "Cubo desligado")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AvisoAcesso: View {
    let detalhe: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("A Cubo não consegue ler as notificações", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.callout.bold())
            Text("Dá Acesso Total ao Disco à app Cubo e volta a abri-la.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Abrir Definições") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .help(detalhe)
    }
}

struct LinhaItem: View {
    @EnvironmentObject var estado: AppState
    let item: ItemEntrada
    var compacta = false
    @StateObject private var criarTarefa = Caixa(false)
    @StateObject private var sobre = Caixa(false)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: Icones.de(item.bundle))
                .resizable().frame(width: compacta ? 26 : 34, height: compacta ? 26 : 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.titulo.isEmpty ? item.app : item.titulo)
                        .font(compacta ? .callout.weight(.semibold) : .body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.quando, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                let detalhe = [item.subtitulo, item.texto].filter { !$0.isEmpty }.joined(separator: " — ")
                if !detalhe.isEmpty {
                    Text(detalhe).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(compacta ? 1 : 2)
                }
                if !compacta {
                    Text(item.app).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .opacity(item.visto ? 0.55 : 1)

            if sobre.v || !compacta {
                HStack(spacing: 2) {
                    if !item.visto {
                        Button { estado.marcarVisto(item) } label: { Image(systemName: "checkmark") }
                            .help("Visto")
                    }
                    if Respostas.podeResponder(item) {
                        Button { Respostas.shared.considerar(item, pedido: true) } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                        }
                        .help("Preparar resposta")
                    }
                    Button { criarTarefa.v = true } label: { Image(systemName: "checklist") }
                        .help("Passar a tarefa")
                    Button { estado.abrirApp(item) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Abrir \(item.app)")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, compacta ? 4 : 6)
        .padding(.horizontal, compacta ? 6 : 0)
        .background(compacta && sobre.v ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { estado.abrirNotificacao(item) }
        .help("Abrir em \(item.app) e marcar como visto")
        .onHover { sobre.v = $0 }
        .sheet(isPresented: $criarTarefa.v) { NovaTarefa(item: item) }
    }
}

struct NovaTarefa: View {
    @EnvironmentObject var estado: AppState
    @Environment(\.dismiss) private var fechar
    let item: ItemEntrada
    @StateObject private var tituloT = Caixa("")
    @StateObject private var quandoT = Caixa(Lembretes.Quando.hoje)
    @StateObject private var erroT = Caixa<String?>(nil)
    @StateObject private var aGuardar = Caixa(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nova tarefa", systemImage: "checklist").font(.headline)
            TextField("O que tens de fazer", text: $tituloT.v)
                .textFieldStyle(.roundedBorder)
            Picker("Para", selection: $quandoT.v) {
                ForEach(Lembretes.Quando.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Fica nos Lembretes da Apple, também no iPhone.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = erroT.v { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { fechar() }.keyboardShortcut(.cancelAction)
                Button("Criar") { criar() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tituloT.v.trimmingCharacters(in: .whitespaces).isEmpty || aGuardar.v)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            let quem = item.titulo.isEmpty ? item.app : item.titulo
            tituloT.v = "Responder a \(quem)"
        }
    }

    private func criar() {
        aGuardar.v = true
        let notas = "\(item.app): " + [item.titulo, item.subtitulo, item.texto].filter { !$0.isEmpty }
            .joined(separator: " — ")
        Task {
            do {
                try await Lembretes.criar(titulo: tituloT.v, notas: notas, quando: quandoT.v)
                estado.marcarVisto(item)
                fechar()
            } catch {
                erroT.v = error.localizedDescription
                aGuardar.v = false
            }
        }
    }
}

// MARK: - Resumo do dia (barra de menus)

struct ResumoDia: View {
    @EnvironmentObject var agenda: Agenda

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = agenda.proximo {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                        if e.startDate <= Date() {
                            Text("A decorrer até \(e.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            (Text(e.startDate.formatted(date: .omitted, time: .shortened)) + Text(" · ")
                             + Text(e.startDate, style: .relative))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if agenda.acessoLembretes {
                Label(agenda.tarefasHoje.isEmpty ? "Sem tarefas para hoje"
                      : "\(agenda.tarefasHoje.count) \(agenda.tarefasHoje.count == 1 ? "tarefa" : "tarefas") para hoje",
                      systemImage: "checklist")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Concentração (barra de menus)

struct ControloFoco: View {
    @EnvironmentObject var estado: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.fill").foregroundStyle(estado.emFoco ? Color.indigo : .secondary)
            if estado.emFoco, let f = estado.focoAte {
                VStack(alignment: .leading, spacing: 1) {
                    Text(estado.focoReuniao.map { "Em reunião: \($0)" } ?? "Concentração até \(f.formatted(date: .omitted, time: .shortened))")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    Text(estado.config.pessoasPrioritarias.isEmpty
                         ? "O cubo está em silêncio"
                         : "Só passam: \(estado.config.pessoasPrioritarias.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Terminar") { estado.terminarFoco() }.controlSize(.small)
            } else {
                Text("Concentração").font(.callout)
                Spacer()
                ForEach([30, 60, 120], id: \.self) { m in
                    Button(m < 60 ? "\(m) min" : "\(m / 60) h") { estado.comecarFoco(minutos: m) }
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(estado.emFoco ? Color.indigo.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Silêncio do Mac (barra de menus)

struct ControloSilencioMac: View {
    @EnvironmentObject var estado: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: estado.macEmSilencio ? "bell.slash.fill" : "bell")
                .foregroundStyle(estado.macEmSilencio ? Color.purple : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac em silêncio").font(.callout)
                Text(estado.macEmSilencio
                     ? "\(estado.modoFocoMac ?? "Não incomodar") · o cubo continua a avisar"
                     : "Avisos do Mac desligados; o cubo continua")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if estado.atalhosSilencioProntos {
                if estado.aMudarSilencio { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(get: { estado.macEmSilencio },
                                         set: { estado.definirSilencioMac($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(estado.aMudarSilencio)
            } else {
                Button("Configurar") { estado.abrirJanela?() }.controlSize(.small)
                    .help("Falta criar dois atalhos — vê o separador Cubo")
            }
        }
        .padding(8)
        .background(estado.macEmSilencio ? Color.purple.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
