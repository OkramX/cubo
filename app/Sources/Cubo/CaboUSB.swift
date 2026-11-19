import Foundation

/// Ligação ao cubo pelo cabo USB (porta série a 115200).
/// Cada pedido é uma linha "@/caminho {json}" e o cubo responde "@R <código> <json>".
/// A porta fica aberta: abri-la reinicia o cubo uma vez (o chip USB mexe no reset).
actor CaboUSB {
    static let shared = CaboUSB()

    private var fd: Int32 = -1
    private var ocupado = false
    private var resto = Data()
    private var horaEnviada = Date.distantPast
    private var proximaProcura = Date.distantPast

    /// Portas USB-série conhecidas (CH340, CP210x, FTDI).
    static func portas() -> [String] {
        let nomes = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return nomes.filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") ||
            $0.hasPrefix("cu.SLAB_USBtoUART") || $0.hasPrefix("cu.usbmodem")
        }.sorted().map { "/dev/" + $0 }
    }

    private func abrir() -> Bool {
        if fd >= 0 { return true }
        guard Date() >= proximaProcura else { return false }
        proximaProcura = Date().addingTimeInterval(5)
        guard let caminho = Self.portas().first else { return false }
        let f = open(caminho, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return false }
        var t = termios()
        tcgetattr(f, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)
        tcsetattr(f, TCSANOW, &t)
        fd = f
        resto.removeAll()
        horaEnviada = .distantPast
        return true
    }

    private func fechar() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func escrever(_ linha: String) -> Bool {
        let d = Array((linha + "\n").utf8)
        var feito = 0
        let limite = Date().addingTimeInterval(2)
        while feito < d.count {
            let n = d[feito...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { feito += n }
            else if errno == EAGAIN, Date() < limite { usleep(5000) }
            else { fechar(); return false }
        }
        return true
    }

    /// Lê até aparecer uma resposta "@R ..." (as outras linhas são registo do cubo e são ignoradas).
    private func esperarResposta(_ timeout: TimeInterval) async -> (Int, Data)? {
        let limite = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 1024)
        while Date() < limite {
            let n = read(fd, &buf, buf.count)
            if n > 0 { resto.append(contentsOf: buf[0..<n]) }
            else if n == 0 || (n < 0 && errno != EAGAIN) { fechar(); return nil }
            while let i = resto.firstIndex(of: 0x0A) {
                let linha = String(decoding: resto[resto.startIndex..<i], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resto.removeSubrange(resto.startIndex...i)
                if linha.hasPrefix("@R ") {
                    let partes = linha.dropFirst(3).split(separator: " ", maxSplits: 1)
                    let codigo = Int(partes.first ?? "") ?? -1
                    return (codigo, Data((partes.count > 1 ? String(partes[1]) : "").utf8))
                }
            }
            if n <= 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        return nil
    }

    private func trocar(_ linha: String, timeout: TimeInterval) async -> (Int, Data)? {
        _ = drenar()
        guard escrever(linha) else { return nil }
        return await esperarResposta(timeout)
    }

    private func drenar() -> Int {
        var buf = [UInt8](repeating: 0, count: 1024)
        var total = 0
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; total += n }
        resto.removeAll()
        return total
    }

    /// Faz um pedido pelo cabo. Devolve nil se não houver cabo ou o cubo não responder.
    func pedido(_ caminho: String, corpo: [String: Any]?, timeout: TimeInterval = 3) async -> (Int, Data)? {
        while ocupado { try? await Task.sleep(nanoseconds: 10_000_000) }
        ocupado = true
        defer { ocupado = false }
        guard abrir() else { return nil }
        // pelo cabo não há relógio da internet: acerta a hora de vez em quando
        if Date().timeIntervalSince(horaEnviada) > 600 {
            if let r = await trocar("@/hora {\"epoch\":\(Int(Date().timeIntervalSince1970))}", timeout: timeout), r.0 == 200 {
                horaEnviada = Date()
            }
        }
        var linha = "@" + caminho
        if let corpo, let d = try? JSONSerialization.data(withJSONObject: corpo) {
            linha += " " + String(decoding: d, as: UTF8.self)
        }
        return await trocar(linha, timeout: timeout)
    }

    var ligado: Bool { fd >= 0 }
}
