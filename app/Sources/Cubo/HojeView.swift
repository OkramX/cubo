import EventKit
import SwiftUI

struct HojeView: View {
    @EnvironmentObject var agenda: Agenda
    @StateObject private var nova = Caixa("")
    @StateObject private var verSemData = Caixa(false)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            tarefas
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            eventos
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Hoje")
        .navigationSubtitle(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .toolbar {
            Button { agenda.atualizar() } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
        }
        .onAppear { agenda.atualizar() }
    }

    // MARK: Tarefas

    private var tarefas: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tarefas").font(.title2.bold())
                Spacer()
                if !agenda.tarefasHoje.isEmpty {
                    Text("\(agenda.tarefasHoje.count) por fazer").foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top])

            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("Nova tarefa para hoje", text: $nova.v)
                    .textFieldStyle(.plain)
                    .onSubmit { agenda.adicionar(nova.v, hoje: true); nova.v = "" }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .padding()

            if !agenda.acessoLembretes {
                SemAcesso(texto: "Para veres as tarefas, dá acesso aos Lembretes à Cubo.",
                          painel: "Privacy_Reminders")
                    .padding(.horizontal)
            }

            List {
                if agenda.tarefasHoje.isEmpty && agenda.acessoLembretes {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(.yellow)
                        Text("Nada para hoje. Bom trabalho!").foregroundStyle(.secondary)
                    }
                }
                ForEach(agenda.tarefasHoje, id: \.calendarItemIdentifier) { r in
                    LinhaTarefa(r: r, atrasada: agenda.atrasada(r))
                }
                if !agenda.tarefasSemData.isEmpty {
                    Section(isExpanded: $verSemData.v) {
                        ForEach(agenda.tarefasSemData, id: \.calendarItemIdentifier) { r in
                            LinhaTarefa(r: r, atrasada: false)
                        }
                    } header: {
                        Text("Sem data (\(agenda.tarefasSemData.count))")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Agenda

    private var eventos: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agenda").font(.title2.bold()).padding([.horizontal, .top])

            if !agenda.acessoCalendario {
                SemAcesso(texto: "Para veres a agenda, dá acesso ao Calendário à Cubo.",
                          painel: "Privacy_Calendars")
                    .padding(.horizontal)
            }

            ForEach(agenda.diaInteiro, id: \.eventIdentifier) { e in
                Text(e.title ?? "")
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(nsColor: e.calendar.color).opacity(0.2), in: Capsule())
                    .padding(.horizontal)
            }

            ScrollView {
                VStack(spacing: 8) {
                    if agenda.eventos.isEmpty && agenda.acessoCalendario {
                        Text("Sem reuniões hoje").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    ForEach(agenda.eventos, id: \.eventIdentifier) { e in
                        CartaoEvento(e: e, proximo: e.eventIdentifier == agenda.proximo?.eventIdentifier)
                    }
                }
                .padding(.horizontal)
            }
        }
        .background(Color.primary.opacity(0.025))
    }
}

struct LinhaTarefa: View {
    @EnvironmentObject var agenda: Agenda
    let r: EKReminder
    let atrasada: Bool
    @StateObject private var feita = Caixa(false)

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation { feita.v = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { agenda.concluir(r) }
            } label: {
                Image(systemName: feita.v ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(feita.v ? Color.green : Color(nsColor: r.calendar.color))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title ?? "").strikethrough(feita.v)
                if atrasada { Text("Atrasada").font(.caption).foregroundStyle(.red) }
                else if let n = r.notes, !n.isEmpty {
                    Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct CartaoEvento: View {
    let e: EKEvent
    let proximo: Bool

    private var aDecorrer: Bool { e.startDate <= Date() && e.endDate > Date() }
    private var passado: Bool { e.endDate <= Date() }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title ?? "").font(.callout.weight(.semibold)).lineLimit(2)
                Text("\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if let l = e.location, !l.isEmpty {
                    Label(l, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if aDecorrer {
                    Text("A decorrer").font(.caption.bold()).foregroundStyle(.orange)
                } else if proximo {
                    Text(e.startDate, style: .relative).font(.caption.bold()).foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(proximo ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .opacity(passado ? 0.45 : 1)
    }
}

struct SemAcesso: View {
    let texto: String
    let painel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(texto).font(.callout)
            Button("Abrir Definições") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?\(painel)")!)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
