import SwiftUI

struct CuboView: View {
    @EnvironmentObject var estado: AppState
    @StateObject private var brilho = Caixa(100.0)
    @StateObject private var brilhoAuto = Caixa(true)
    @StateObject private var endereco = Caixa("")
    @StateObject private var token = Caixa("")
    @StateObject private var verToken = Caixa(false)
    @StateObject private var pessoa = Caixa("")
    @StateObject private var redes = Caixa<CubeClient.Redes?>(nil)
    @StateObject private var novaRede = Caixa("")
    @StateObject private var novaSenha = Caixa("")
    @StateObject private var erroRede = Caixa<String?>(nil)
    @StateObject private var extras = Extras.shared
    @StateObject private var cidade = Caixa(Extras.shared.cidade)
    @StateObject private var erroCidade = Caixa(false)

    var body: some View {
        Form {
            Section("Estado") {
                if let e = estado.estadoCubo {
                    LabeledContent("Ligação") { Label("Ligado", systemImage: "circle.fill").foregroundStyle(.green) }
                    LabeledContent("Firmware", value: e.versao)
                    LabeledContent("Endereço", value: e.wifi == false ? "cabo USB (sem Wi-Fi)" : e.ip)
                    LabeledContent("Sinal Wi-Fi") { Text(sinal(e.rssi)) }
                    LabeledContent("Ligado há", value: duracao(e.uptime_s))
                    LabeledContent("Hora", value: e.hora_ok ? "Certa" : "A acertar…")
                } else {
                    LabeledContent("Ligação") { Label("Desligado", systemImage: "circle.fill").foregroundStyle(.red) }
                    if estado.aProcurarCubo {
                        HStack { ProgressView().controlSize(.small); Text("A procurar o cubo na rede…") }
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Confirma que o cubo está ligado à corrente e numa rede Wi-Fi que conhece.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Procurar o cubo agora") {
                            Task {
                                if let e = await estado.procurarCubo() {
                                    estado.estadoCubo = e; estado.cuboOnline = true
                                    endereco.v = estado.config.cuboURL
                                }
                            }
                        }
                    }
                }
                if estado.ultimoEnvioFalhou {
                    Label("A última notificação não chegou ao cubo.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if estado.scriptAntigoAtivo {
                    Label("O envio para o cubo ainda é feito pelo script antigo.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Enviar teste") { estado.enviarTeste() }
                    Button("Limpar contador") { Task { await estado.cubo.limpar() } }
                    Spacer()
                    Button("Abrir página do cubo") {
                        if let u = URL(string: estado.config.cuboURL) { NSWorkspace.shared.open(u) }
                    }
                }
            }

            Section {
                if let r = redes.v {
                    ForEach(r.redes, id: \.self) { n in
                        HStack {
                            Image(systemName: n == r.atual ? "wifi" : "wifi.slash")
                                .foregroundStyle(n == r.atual ? Color.green : .secondary)
                            Text(n)
                            if n == r.atual { Text("ligado agora").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if n != r.atual {
                                Button { Task { redes.v = await estado.cubo.apagarRede(n) ?? redes.v } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Esquecer esta rede")
                            }
                        }
                    }
                } else if estado.cuboOnline {
                    Text("A carregar…").foregroundStyle(.secondary)
                }
                TextField("Nome da rede (ex.: Escritório)", text: $novaRede.v)
                SecureField("Palavra-passe da rede", text: $novaSenha.v)
                if let e = erroRede.v { Text(e).font(.caption).foregroundStyle(.red) }
                Button("Acrescentar rede ao cubo") {
                    let n = novaRede.v.trimmingCharacters(in: .whitespaces), s = novaSenha.v
                    Task {
                        if let r = await estado.cubo.adicionarRede(n, s) {
                            redes.v = r; novaRede.v = ""; novaSenha.v = ""; erroRede.v = nil
                        } else {
                            erroRede.v = "O cubo não aceitou. Confirma que está ligado e que o nome tem até 32 letras."
                        }
                    }
                }
                .disabled(novaRede.v.trimmingCharacters(in: .whitespaces).isEmpty || !estado.cuboOnline)
            } header: {
                Text("Redes Wi-Fi do cubo")
            } footer: {
                Text("O cubo liga-se sozinho à rede conhecida com melhor sinal (até 6). Antes de o levares para outro sítio, acrescenta aqui a rede de lá. Se não conhecer nenhuma, cria a rede \"Cubo-Setup\" para o configurares. A app encontra o cubo sozinha em qualquer rede.")
            }

            Section {
                LabeledContent("Treino de hoje", value: extras.treino.isEmpty ? "—" : extras.treino)
                LabeledContent("Forma", value: extras.forma.isEmpty ? "—" : extras.forma)
                LabeledContent("Tempo em \(extras.cidade)", value: extras.tempo.isEmpty ? "—" : extras.tempo)
                HStack {
                    TextField("Cidade", text: $cidade.v)
                    Button("Mudar") {
                        Task { erroCidade.v = !(await extras.mudarCidade(cidade.v)) }
                    }
                    Button { Task { await extras.atualizar() } } label: { Image(systemName: "arrow.clockwise") }
                }
                if erroCidade.v { Text("Não encontrei essa cidade.").foregroundStyle(.red).font(.caption) }
            } header: { Text("Relógio do cubo") } footer: {
                Text("O treino e a forma vêm da OkramX; o tempo do Open-Meteo. Antes de cada reunião o cubo mostra uma contagem de 10 min, e durante a Concentração um anel com o tempo que falta.")
            }

            Section("Brilho") {
                Toggle("Automático (dia e noite)", isOn: $brilhoAuto.v)
                    .onChange(of: brilhoAuto.v) { _, auto in
                        Task { await estado.cubo.brilho(auto ? -1 : Int(brilho.v)) }
                    }
                if !brilhoAuto.v {
                    Slider(value: $brilho.v, in: 5...100, step: 5) {
                        Text("\(Int(brilho.v))%")
                    } onEditingChanged: { aMexer in
                        if !aMexer { Task { await estado.cubo.brilho(Int(brilho.v)) } }
                    }
                }
            }

            Section {
                HStack {
                    Toggle("Tocar um som quando entra uma notificação", isOn: liga(\.som))
                    Spacer()
                    Button("Ouvir") { Som.tocar() }
                }
                Toggle("Lembrar uma pausa a cada 50 min ao computador", isOn: liga(\.pausa))
            } header: { Text("Som e pausas") } footer: {
                Text("Toca mesmo com o Mac em silêncio. Durante a Concentração só toca para as pessoas prioritárias.")
            }

            Section("O que aparece no cubo") {
                Toggle("Remetente", isOn: liga(\.mostrarTitulo))
                Toggle("Assunto", isOn: liga(\.mostrarSubtitulo))
                Toggle("Texto da mensagem", isOn: liga(\.mostrarTexto))
                Picker("Códigos de verificação", selection: liga(\.codigos)) {
                    Text("Esconder o código").tag("esconder")
                    Text("Não enviar").tag("ignorar")
                    Text("Mostrar").tag("mostrar")
                }
            }

            Section {
                Toggle("Todas as apps", isOn: liga(\.todasAsApps))
                ForEach(listaApps, id: \.0) { (bundle, n) in
                    Toggle(isOn: Binding(get: { estado.appEscolhida(bundle) },
                                         set: { estado.escolherApp(bundle, $0) })) {
                        HStack {
                            Image(nsImage: Icones.de(bundle)).resizable().frame(width: 20, height: 20)
                            Text(AppState.nomeDaApp(bundle))
                            if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(estado.config.todasAsApps)
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("As notificações destas apps aparecem na Entrada e no cubo. O número é quantas o Mac tem guardadas.")
            }

            Section("Ligação") {
                TextField("Endereço do cubo", text: $endereco.v)
                HStack {
                    if verToken.v { TextField("Código secreto", text: $token.v) }
                    else { SecureField("Código secreto", text: $token.v) }
                    Button { verToken.v.toggle() } label: { Image(systemName: verToken.v ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                Text("O código secreto tem de ser igual ao que está no cubo.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Guardar") {
                    estado.config.cuboURL = endereco.v
                    estado.config.token = token.v
                    estado.gravarConfig()
                }
                .disabled(endereco.v == estado.config.cuboURL && token.v == estado.config.token)
            }

            Section {
                ForEach(estado.config.pessoasPrioritarias, id: \.self) { p in
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(p)
                        Spacer()
                        Button { estado.removerPessoa(p) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Acrescentar pessoa (nome como aparece na notificação)", text: $pessoa.v)
                        .onSubmit { estado.adicionarPessoa(pessoa.v); pessoa.v = "" }
                    Button("Acrescentar") { estado.adicionarPessoa(pessoa.v); pessoa.v = "" }
                        .disabled(pessoa.v.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !estado.remetentesFrequentes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sugestões, de quem te escreve mais:").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(estado.remetentesFrequentes, id: \.self) { r in
                                    Button("+ \(r)") { estado.adicionarPessoa(r) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Concentração")
            } footer: {
                Text("Durante a Concentração o cubo fica em silêncio, exceto para estas pessoas. Tudo continua a aparecer na Entrada.")
            }

            Section {
                if estado.atalhosSilencioProntos {
                    Toggle(isOn: Binding(get: { estado.macEmSilencio }, set: { estado.definirSilencioMac($0) })) {
                        Text("Mac em silêncio (Não incomodar)")
                        if let m = estado.modoFocoMac { Text("Ligado: \(m)") }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Falta um passo, só uma vez: criar dois atalhos na app Atalhos.")
                            .font(.callout.weight(.semibold))
                        Text("""
                        1. Abre a app Atalhos e carrega em + para criar um atalho novo.
                        2. Procura a ação «Definir foco», escolhe «Não incomodar» e «Ligar» (até ser desligado).
                        3. Dá ao atalho o nome: \(SilencioMac.atalhoLigar)
                        4. Cria outro igual com «Desligar» e o nome: \(SilencioMac.atalhoDesligar)
                        """)
                        .font(.callout).textSelection(.enabled)
                        HStack {
                            Button("Abrir Atalhos") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                            }
                            Button("Já criei, verificar") { estado.verificarAtalhosSilencio() }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Silêncio no Mac")
            } footer: {
                Text("Com o Não incomodar ligado, o Mac deixa de mostrar avisos, mas o cubo e a Entrada continuam a receber tudo. Também funciona se o ligares pela Central de Controlo.")
            }

            Section("Atalhos de teclado") {
                ForEach(AtalhosGlobais.lista, id: \.teclas) { a in
                    LabeledContent(a.descricao) { Text(a.teclas).monospaced() }
                }
                LabeledContent("Mudar de separador") { Text("⌘1  ⌘2  ⌘3").monospaced() }
                LabeledContent("Entrada: visto · tarefa · abrir") { Text("E  T  O").monospaced() }
                LabeledContent("Entrada: tudo visto") { Text("⇧⌘E").monospaced() }
            }

            Section("Mac") {
                Toggle("Abrir a Cubo ao iniciar sessão", isOn: Binding(
                    get: { estado.abrirNoArranque }, set: { estado.abrirNoArranque = $0 }))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cubo")
        .onAppear {
            endereco.v = estado.config.cuboURL
            token.v = estado.config.token
            Task {
                await estado.atualizarEstadoCubo()
                endereco.v = estado.config.cuboURL
                redes.v = await estado.cubo.redes()
            }
        }
    }

    private var listaApps: [(String, Int)] {
        var vistos = Set<String>()
        var out: [(String, Int)] = []
        for (b, n) in estado.appsConhecidas where !b.hasPrefix("_system") {
            out.append((b, n)); vistos.insert(b.lowercased())
        }
        for b in estado.config.apps.keys.sorted() where !vistos.contains(b.lowercased()) {
            out.append((b, 0))
        }
        return out
    }

    private func liga<T>(_ k: WritableKeyPath<CuboConfig, T>) -> Binding<T> {
        Binding(get: { estado.config[keyPath: k] },
                set: { estado.config[keyPath: k] = $0; estado.gravarConfig() })
    }

    private func sinal(_ rssi: Int) -> String {
        let q = rssi >= -55 ? "Excelente" : rssi >= -67 ? "Bom" : rssi >= -75 ? "Fraco" : "Muito fraco"
        return "\(q) (\(rssi) dBm)"
    }

    private func duracao(_ s: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
        f.unitsStyle = .short
        return f.string(from: TimeInterval(s)) ?? "\(s) s"
    }
}
