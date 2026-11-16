import Carbon
import Foundation

/// Atalhos de teclado globais (funcionam em qualquer app, sem pedir permissões).
enum AtalhosGlobais {
    private static var acoes: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var instalado = false

    /// ⌃⌥C abre a Cubo · ⌃⌥F liga/desliga a Concentração
    static let lista: [(teclas: String, descricao: String)] = [
        ("⌃⌥C", "Abrir a Cubo (em qualquer app)"),
        ("⌃⌥F", "Ligar ou desligar a Concentração (1 hora)"),
    ]

    static func registar(abrir: @escaping () -> Void, foco: @escaping () -> Void) {
        instalarHandler()
        let mods = UInt32(controlKey | optionKey)
        adicionar(id: 1, tecla: UInt32(kVK_ANSI_C), mods: mods, acao: abrir)
        adicionar(id: 2, tecla: UInt32(kVK_ANSI_F), mods: mods, acao: foco)
    }

    private static func adicionar(id: UInt32, tecla: UInt32, mods: UInt32, acao: @escaping () -> Void) {
        guard acoes[id] == nil else { acoes[id] = acao; return }
        acoes[id] = acao
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4355_424F), id: id)   // 'CUBO'
        RegisterEventHotKey(tecla, mods, hid, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private static func instalarHandler() {
        guard !instalado else { return }
        instalado = true
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, _ in
            var hid = EventHotKeyID()
            GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
            let id = hid.id
            DispatchQueue.main.async { AtalhosGlobais.acoes[id]?() }
            return noErr
        }, 1, &tipo, nil, nil)
    }
}
