import EventKit
import Foundation

/// Cria tarefas nos Lembretes da Apple (sincronizam com o iPhone).
enum Lembretes {
    static let store = EKEventStore()

    enum Quando: String, CaseIterable, Identifiable {
        case semData = "Sem data", hoje = "Hoje", amanha = "Amanhã"
        var id: String { rawValue }
        var data: Date? {
            switch self {
            case .semData: return nil
            case .hoje: return Date()
            case .amanha: return Calendar.current.date(byAdding: .day, value: 1, to: Date())
            }
        }
    }

    static func criar(titulo: String, notas: String, quando: Quando) async throws {
        try await criar(titulo: titulo, notas: notas, data: quando.data)
    }

    static func criar(titulo: String, notas: String, data: Date?) async throws {
        guard try await store.requestFullAccessToReminders() else {
            throw NSError(domain: "Cubo", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Sem acesso aos Lembretes. Ativa a Cubo em Definições do Sistema → Privacidade e Segurança → Lembretes."])
        }
        let r = EKReminder(eventStore: store)
        r.title = titulo
        r.notes = notas
        guard let lista = store.defaultCalendarForNewReminders() else {
            throw NSError(domain: "Cubo", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Não encontrei nenhuma lista nos Lembretes."])
        }
        r.calendar = lista
        if let d = data {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: d)
        }
        try store.save(r, commit: true)
    }
}
