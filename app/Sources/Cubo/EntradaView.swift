import SwiftUI

struct EntradaView: View {
    @EnvironmentObject var estado: AppState
    @StateObject private var filtroApp = Caixa<String?>(nil)
    @StateObject private var mostrarVistos = Caixa(false)
    @StateObject private var procura = Caixa("")
    @StateObject private var selecao = Caixa<ItemEntrada.ID?>(nil)
    @StateObject private var tarefaPara = Caixa<ItemEntrada?>(nil)

    private var selecionado: ItemEntrada? { estado.itens.first { $0.id == selecao.v } }

    /// Depois de marcar como visto, passa para a seguinte da lista.
    private func vistoESeguinte(_ i: ItemEntrada) {
        let lista = filtrados
        let k = lista.firstIndex(of: i)
        estado.marcarVisto(i)
        if let k, !mostrarVistos.v {
            let resto = lista.filter { $0.id != i.id }
            selecao.v = resto.isEmpty ? nil : resto[min(k, resto.count - 1)].id
        }
    }

    private var filtrados: [ItemEntrada] {
        estado.itens.filter { i in
            (mostrarVistos.v || !i.visto)
            && (filtroApp.v == nil || i.app == filtroApp.v)
            && (procura.v.isEmpty || [i.titulo, i.subtitulo, i.texto, i.app]
                    .joined(separator: " ").localizedCaseInsensitiveContains(procura.v))
        }
    }

    private var grupos: [(String, [ItemEntrada])] {
        let cal = Calendar.current
        var hoje: [ItemEntrada] = [], ontem: [ItemEntrada] = [], antes: [ItemEntrada] = []
        for i in filtrados {
            if cal.isDateInToday(i.quando) { hoje.append(i) }
            else if cal.isDateInYesterday(i.quando) { ontem.append(i) }
            else { antes.append(i) }
        }
        return [("Hoje", hoje), ("Ontem", ontem), ("Antes", antes)].filter { !$0.1.isEmpty }
    }

    private var appsNaEntrada: [String] {
        Array(Set(estado.itens.map(\.app))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let e = estado.erroBD { AvisoAcesso(detalhe: e).padding() }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(texto: "Todas", ativo: filtroApp.v == nil) { filtroApp.v = nil }
                    ForEach(appsNaEntrada, id: \.self) { a in
                        let b = estado.itens.first { $0.app == a }?.bundle ?? ""
                        Chip(texto: a, icone: Icones.de(b), ativo: filtroApp.v == a) { filtroApp.v = a }
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }

            if grupos.isEmpty {
                ContentUnavailableView {
                    Label(mostrarVistos.v ? "Sem notificações" : "Está tudo visto", systemImage: "checkmark.circle")
                } description: {
                    Text("As notificações novas aparecem aqui e no cubo.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selecao.v) {
                    ForEach(grupos, id: \.0) { g in
                        Section(g.0) {
                            ForEach(g.1) { i in LinhaItem(item: i).tag(i.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .onKeyPress(characters: CharacterSet(charactersIn: "etoETO")) { k in
                    guard let i = selecionado else { return .ignored }
                    switch k.characters.lowercased() {
                    case "e": vistoESeguinte(i)
                    case "t": tarefaPara.v = i
                    case "o": estado.abrirApp(i)
                    default: return .ignored
                    }
                    return .handled
                }
                .sheet(item: $tarefaPara.v) { i in NovaTarefa(item: i).environmentObject(estado) }
            }
        }
        .navigationTitle("Entrada")
        .searchable(text: $procura.v, prompt: "Procurar")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $mostrarVistos.v) { Label("Mostrar vistos", systemImage: "eye") }
                    .help("Mostrar também as já vistas")
                Button { estado.marcarTudoVisto() } label: { Label("Tudo visto", systemImage: "checkmark.circle") }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(estado.porVer.isEmpty)
                    .help("Marcar tudo como visto (limpa também o cubo)")
                Menu {
                    Button("Apagar as já vistas", role: .destructive) { estado.apagarVistos() }
                } label: { Label("Mais", systemImage: "ellipsis.circle") }
            }
        }
    }
}

struct Chip: View {
    let texto: String
    var icone: NSImage? = nil
    let ativo: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 5) {
                if let icone { Image(nsImage: icone).resizable().frame(width: 16, height: 16) }
                Text(texto).font(.callout)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(ativo ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(ativo ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
