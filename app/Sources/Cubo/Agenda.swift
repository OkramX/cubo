import EventKit
import Foundation

/// Tarefas (Lembretes) e eventos (Calendário) de hoje.
@MainActor
final class Agenda: ObservableObject {
    @Published var eventos: [EKEvent] = []
    @Published var diaInteiro: [EKEvent] = []
    @Published var tarefasHoje: [EKReminder] = []
    @Published var tarefasSemData: [EKReminder] = []
    @Published var acessoCalendario = false
    @Published var acessoLembretes = false
    @Published var erro: String?

    private var store: EKEventStore { Lembretes.store }
    private var timer: Timer?
    private var ultimoResumo: [String: AnyHashable] = [:]
    private var ultimoEnvioResumo = Date.distantPast
    var cubo: () -> CubeClient = { CubeClient(base: "", token: "") }
    var focoAte: () -> Date? = { nil }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.atualizar() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.atualizar() }
        }
        Task { await pedirAcesso() }
    }

    func pedirAcesso() async {
        acessoCalendario = (try? await store.requestFullAccessToEvents()) ?? false
        acessoLembretes = (try? await store.requestFullAccessToReminders()) ?? false
        atualizar()
    }

    /// Próximo evento com hora: o que está a decorrer, ou o seguinte.
    var proximo: EKEvent? {
        let agora = Date()
        return eventos.first { $0.endDate > agora }
    }

    func atualizar() {
        let cal = Calendar.current
        let inicio = cal.startOfDay(for: Date())
        let fim = cal.date(byAdding: .day, value: 1, to: inicio)!

        if acessoCalendario {
            let p = store.predicateForEvents(withStart: inicio, end: fim, calendars: nil)
            let todos = store.events(matching: p).sorted { $0.startDate < $1.startDate }
            eventos = todos.filter { !$0.isAllDay }
            diaInteiro = todos.filter { $0.isAllDay }
        }

        guard acessoLembretes else { enviarResumo(); return }
        let p = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: p) { lista in
            let lista = lista ?? []
            Task { @MainActor in
                var hoje: [EKReminder] = [], semData: [EKReminder] = []
                for r in lista {
                    if let dc = r.dueDateComponents, let d = cal.date(from: dc) {
                        if d < fim { hoje.append(r) }
                    } else {
                        semData.append(r)
                    }
                }
                func data(_ r: EKReminder) -> Date { r.dueDateComponents.flatMap { cal.date(from: $0) } ?? .distantFuture }
                self.tarefasHoje = hoje.sorted { data($0) < data($1) }
                self.tarefasSemData = semData.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
                self.enviarResumo()
            }
        }
    }

    // MARK: Ações

    func concluir(_ r: EKReminder) {
        r.isCompleted = true
        do { try store.save(r, commit: true) } catch { erro = error.localizedDescription }
        atualizar()
    }

    func adicionar(_ titulo: String, hoje: Bool) {
        let t = titulo.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let lista = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = t
        r.calendar = lista
        if hoje {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        }
        do { try store.save(r, commit: true) } catch { erro = error.localizedDescription }
        atualizar()
    }

    func atrasada(_ r: EKReminder) -> Bool {
        guard let dc = r.dueDateComponents, let d = Calendar.current.date(from: dc) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    // MARK: Resumo para o cubo

    /// Envia só quando muda, ou a cada 10 min para o cubo saber que o Mac continua ligado.
    func enviarResumo() {
        var dados: [String: AnyHashable] = ["tarefas": acessoLembretes ? tarefasHoje.count : -1]
        if let f = focoAte(), f > Date() { dados["foco_ate"] = Int(f.timeIntervalSince1970) }
        if let e = proximo {
            dados["evento"] = Preparar.ascii(e.title ?? "Evento")
            dados["inicio"] = Int(e.startDate.timeIntervalSince1970)
            dados["fim"] = Int(e.endDate.timeIntervalSince1970)
        } else {
            dados["evento"] = ""
        }
        guard dados != ultimoResumo || Date().timeIntervalSince(ultimoEnvioResumo) > 600 else { return }
        let c = cubo()
        Task {
            if await c.enviar("/resumo", corpo: dados) == 200 {
                self.ultimoResumo = dados
                self.ultimoEnvioResumo = Date()
            }
        }
    }
}
