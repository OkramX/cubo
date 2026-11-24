import AppKit
import Combine
import SwiftUI

// Painel da barra de menus que nasce do notch, como a Dynamic Island do iPhone.
// Um ícone na barra (NSStatusItem) abre e fecha um painel preto que cresce a partir
// do recorte da câmara; em ecrãs sem notch cresce de um "notch" imaginário ao centro.

// MARK: - Forma do notch

struct FormaNotch: Shape {
    var raioCima: CGFloat
    var raioBaixo: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(raioCima, raioBaixo) }
        set { raioCima = newValue.first; raioBaixo = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, c = raioCima, b = min(raioBaixo, (w - 2 * c) / 2, h - c)
        p.move(to: .init(x: 0, y: 0))
        p.addQuadCurve(to: .init(x: c, y: c), control: .init(x: c, y: 0))
        p.addLine(to: .init(x: c, y: h - b))
        p.addQuadCurve(to: .init(x: c + b, y: h), control: .init(x: c, y: h))
        p.addLine(to: .init(x: w - c - b, y: h))
        p.addQuadCurve(to: .init(x: w - c, y: h - b), control: .init(x: w - c, y: h))
        p.addLine(to: .init(x: w - c, y: c))
        p.addQuadCurve(to: .init(x: w, y: 0), control: .init(x: w - c, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Estado da animação

@MainActor
final class EstadoNotch: ObservableObject {
    @Published var aberto = false
    @Published var notch = CGSize(width: 185, height: 32)
    @Published var alturaMax: CGFloat = 760
    var fechar: () -> Void = {}
}

struct VistaNotch: View {
    @ObservedObject var n: EstadoNotch
    @EnvironmentObject var estado: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var conteudo = CGSize(width: 384, height: 300)

    private let largura: CGFloat = 384

    var body: some View {
        let ab = n.aberto
        let w = ab ? largura + 2 * 14 : n.notch.width + 2 * 6
        let h = ab ? conteudo.height + n.notch.height : n.notch.height

        ZStack(alignment: .top) {
            // Clicar fora do painel fecha-o
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { n.fechar() }
                .allowsHitTesting(ab)

            ZStack(alignment: .top) {
                FormaNotch(raioCima: ab ? 14 : 6, raioBaixo: ab ? 32 : 10)
                    .fill(.black)
                    .shadow(color: .black.opacity(ab ? 0.45 : 0), radius: 18, y: 8)

                // topo + rodapé ocupam ~150 pt; o meio desliza se não couber
                MenuView(limiteMeio: max(200, n.alturaMax - n.notch.height - 170))
                    .padding(.top, n.notch.height - 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: largura)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { conteudo = $0 }
                    .opacity(ab ? 1 : 0)
                    .scaleEffect(ab ? 1 : 0.6, anchor: .top)
                    .blur(radius: ab ? 0 : 8)
                    .environment(\.colorScheme, .dark)
            }
            .frame(width: w, height: h, alignment: .top)
            .clipShape(FormaNotch(raioCima: ab ? 14 : 6, raioBaixo: ab ? 32 : 10))
            .contentShape(FormaNotch(raioCima: ab ? 14 : 6, raioBaixo: ab ? 32 : 10))
            .onTapGesture {}  // cliques dentro não fecham
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(ab ? .spring(response: 0.42, dampingFraction: 0.78)
                      : .spring(response: 0.32, dampingFraction: 0.95), value: ab)
        .onAppear {
            estado.abrirJanela = {
                n.fechar()
                openWindow(id: "principal")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Janela transparente por cima da barra de menus

final class PainelNotch: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { aoEsc?() }
    var aoEsc: (() -> Void)?
}

@MainActor
final class ControladorNotch: NSObject {
    private let estado: AppState
    private let agenda: Agenda
    private let n = EstadoNotch()
    private var painel: PainelNotch!
    private var item: NSStatusItem!
    private var vigias: [Any] = []
    private var subs = Set<AnyCancellable>()
    private var fecho: DispatchWorkItem?

    private var tamanho = NSSize(width: 520, height: 760)

    init(estado: AppState, agenda: Agenda) {
        self.estado = estado
        self.agenda = agenda
        super.init()
        criarItem()
        criarPainel()
        n.fechar = { [weak self] in self?.fechar() }
        ControladorNotch.atual = self
        // Preparar a vista (e o "abrir janela") logo no arranque, sem se ver
        painel.alphaValue = 0
        painel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.painel.orderOut(nil)
            self?.painel.alphaValue = 1
        }
    }

    // MARK: Ícone na barra

    private func criarItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicar)
        item.button?.imagePosition = .imageLeading
        atualizarIcone()
        estado.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.atualizarIcone() }
            .store(in: &subs)
        Respostas.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.atualizarIcone() }
            .store(in: &subs)
    }

    private func atualizarIcone() {
        let nome = estado.emFoco ? "moon.fill" : (estado.porVer.isEmpty ? "cube" : "cube.fill")
        let img = NSImage(systemSymbolName: nome, accessibilityDescription: "Cubo")
        img?.isTemplate = true
        item.button?.image = img
        let c = estado.porVer.count, r = Respostas.shared.prontos
        item.button?.title = (c > 0 ? " \(c)" : "") + (r > 0 ? " ✎\(r)" : "")
    }

    func alternar() { clicar() }
    /// Abre o painel (se ainda não estiver aberto)
    func mostrar() { if !n.aberto { abrir() } }
    static weak var atual: ControladorNotch?

    @objc private func clicar() {
        n.aberto ? fechar() : abrir()
    }

    // MARK: Painel

    private func criarPainel() {
        painel = PainelNotch(contentRect: .init(origin: .zero, size: tamanho),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        painel.isOpaque = false
        painel.backgroundColor = .clear
        painel.hasShadow = false
        painel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        painel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        painel.isMovable = false
        painel.hidesOnDeactivate = false
        painel.aoEsc = { [weak self] in self?.fechar() }

        let vista = VistaNotch(n: n)
            .environmentObject(estado)
            .environmentObject(agenda)
        let host = NSHostingView(rootView: vista)
        host.sizingOptions = []
        host.frame = .init(origin: .zero, size: tamanho)
        painel.contentView = host
    }

    /// Ecrã onde está o ícone da barra (o Mac pode ter monitor externo).
    private var ecra: NSScreen {
        item.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func medirNotch(_ s: NSScreen) -> CGSize {
        let barra = s.frame.maxY - s.visibleFrame.maxY
        if s.safeAreaInsets.top > 0,
           let esq = s.auxiliaryTopLeftArea, let dir = s.auxiliaryTopRightArea {
            return CGSize(width: dir.minX - esq.maxX, height: s.safeAreaInsets.top)
        }
        // Sem notch: um "notch" imaginário ao centro, da altura da barra de menus
        return CGSize(width: 180, height: max(barra, 24))
    }

    private func abrir() {
        fecho?.cancel()
        let s = ecra
        n.notch = medirNotch(s)
        // O painel nunca passa do fundo do ecrã (deixa 40 pt de margem)
        tamanho.height = max(400, s.frame.height - 40)
        n.alturaMax = tamanho.height - 30
        painel.contentView?.frame = .init(origin: .zero, size: tamanho)
        let f = s.frame
        painel.setFrame(.init(x: f.midX - tamanho.width / 2, y: f.maxY - tamanho.height,
                              width: tamanho.width, height: tamanho.height), display: true)
        painel.makeKeyAndOrderFront(nil)
        estado.objectWillChange.send()
        DispatchQueue.main.async { [weak self] in self?.n.aberto = true }

        // Clicar noutra app ou noutra parte do ecrã fecha o painel
        if vigias.isEmpty {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                         handler: { [weak self] _ in
                Task { @MainActor in self?.fechar() }
            }) { vigias.append(m) }
        }
    }

    func fechar() {
        guard n.aberto else { return }
        n.aberto = false
        vigias.forEach { NSEvent.removeMonitor($0) }
        vigias.removeAll()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.n.aberto else { return }
            self.painel.orderOut(nil)
        }
        fecho = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }
}

// MARK: - Arranque

@MainActor
final class Delegado: NSObject, NSApplicationDelegate {
    let estado = AppState()
    let agenda = Agenda()
    private var notch: ControladorNotch?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TesteRespostas.correrSePedido()
        TesteCaixa.correrSePedido()
        TesteAssistente.correrSePedido(estado)
        if CommandLine.arguments.contains("--testar-assistente") { return }
        notch = ControladorNotch(estado: estado, agenda: agenda)
        ligar()
        TesteRespostas.exemplo { [weak self] in self?.notch?.alternar() }
    }

    // Uma app com uma só janela fecha-se quando a janela fecha; a Cubo vive na barra de menus
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
