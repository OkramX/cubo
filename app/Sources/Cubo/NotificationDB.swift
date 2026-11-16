import Foundation
import SQLite3

/// Leitura (só leitura) da base de dados do Centro de Notificações do macOS.
final class NotificationDB {
    struct Registo {
        let recID: Int64
        let bundle: String
        let data: Data
        let quando: Date
    }

    enum Erro: Error, CustomStringConvertible {
        case semAcesso(String)
        var description: String { if case .semAcesso(let s) = self { return s }; return "" }
    }

    private var db: OpaquePointer?
    private(set) var caminho = ""

    static func caminhos() -> [String] {
        var c = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path]
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 {
            c.append(String(cString: buf) + "com.apple.notificationcenter/db2/db")
        }
        return c
    }

    func abrir() throws {
        fechar()
        var erros: [String] = []
        for p in Self.caminhos() {
            var h: OpaquePointer?
            if sqlite3_open_v2(p, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                var st: OpaquePointer?
                if sqlite3_prepare_v2(h, "SELECT COUNT(*) FROM record", -1, &st, nil) == SQLITE_OK,
                   sqlite3_step(st) == SQLITE_ROW {
                    sqlite3_finalize(st)
                    db = h
                    caminho = p
                    return
                }
                erros.append(String(cString: sqlite3_errmsg(h)))
                sqlite3_finalize(st)
            } else {
                erros.append(h.map { String(cString: sqlite3_errmsg($0)) } ?? "não abre")
            }
            sqlite3_close(h)
        }
        throw Erro.semAcesso(erros.joined(separator: "; "))
    }

    func fechar() {
        if db != nil { sqlite3_close(db); db = nil }
    }

    var aberta: Bool { db != nil }

    func maxRecID() throws -> Int64 {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rec_id),0) FROM record", -1, &st, nil) == SQLITE_OK,
              sqlite3_step(st) == SQLITE_ROW else { throw erroAtual() }
        return sqlite3_column_int64(st, 0)
    }

    func registos(depoisDe id: Int64, desde: Date? = nil) throws -> [Registo] {
        var sql = """
            SELECT r.rec_id, a.identifier, r.data, COALESCE(r.delivered_date, r.request_date, 0)
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?
            """
        if desde != nil { sql += " AND COALESCE(r.delivered_date, r.request_date, 0) >= ?" }
        sql += " ORDER BY r.rec_id"
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw erroAtual() }
        sqlite3_bind_int64(st, 1, id)
        if let d = desde { sqlite3_bind_double(st, 2, d.timeIntervalSinceReferenceDate) }
        var out: [Registo] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw erroAtual() }
            let rec = sqlite3_column_int64(st, 0)
            let ident = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            var data = Data()
            if let b = sqlite3_column_blob(st, 2) {
                data = Data(bytes: b, count: Int(sqlite3_column_bytes(st, 2)))
            }
            let t = sqlite3_column_double(st, 3)
            out.append(Registo(recID: rec, bundle: ident, data: data,
                               quando: t > 0 ? Date(timeIntervalSinceReferenceDate: t) : Date()))
        }
        return out
    }

    /// Apps que têm notificações guardadas, com a quantidade.
    func appsComNotificacoes() -> [(String, Int)] {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        let sql = """
            SELECT a.identifier, COUNT(*) FROM record r JOIN app a ON a.app_id = r.app_id
            GROUP BY a.identifier ORDER BY COUNT(*) DESC
            """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [(String, Int)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            if let c = sqlite3_column_text(st, 0) {
                out.append((String(cString: c), Int(sqlite3_column_int(st, 1))))
            }
        }
        return out
    }

    private func erroAtual() -> Erro { .semAcesso(db.map { String(cString: sqlite3_errmsg($0)) } ?? "fechada") }

    struct Info {
        var titulo = "", subtitulo = "", texto = ""
        var conversa: String?     // identificador da conversa (ex.: WhatsApp "…@s.whatsapp.net")
        var link: String?         // link direto que a app deixou (ex.: Calendário "ical://…")
        var idMensagem: String?   // Message-ID de um email ("<…@…>")
    }

    /// Título, subtítulo, texto e, quando existem, os dados para abrir o sítio certo.
    static func decodificar(_ blob: Data) -> Info? {
        guard let pl = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any]
        else { return nil }
        let req = pl["req"] as? [String: Any] ?? [:]
        func campo(_ k: String) -> String {
            (req[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var i = Info(titulo: campo("titl"), subtitulo: campo("subt"), texto: campo("body"))
        if !campo("thre").isEmpty { i.conversa = campo("thre") }
        if !campo("durl").isEmpty { i.link = campo("durl") }
        if let usda = req["usda"] as? Data,
           let arq = try? PropertyListSerialization.propertyList(from: usda, format: nil) as? [String: Any],
           let objs = arq["$objects"] as? [Any] {
            for case let s as String in objs {
                if s.hasPrefix("<"), s.hasSuffix(">"), s.contains("@"), !s.contains(" ") { i.idMensagem = s; break }
            }
        }
        return i
    }
}
