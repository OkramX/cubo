import AppKit
import SwiftUI

// Mascote: de 5 em 5 minutos o cubo do logótipo entra pelo canto inferior direito do ecrã
// aos saltinhos, pisca os olhos e volta a sair. Não apanha cliques (passam para o que está por baixo).

@MainActor
final class EstadoMascote: ObservableObject {
    @Published var x: CGFloat = 300        // deslocamento para a direita (fora do ecrã)
    @Published var y: CGFloat = 0          // altura do salto (negativo = para cima)
    @Published var sx: CGFloat = 1         // esmagar/esticar ao aterrar
    @Published var sy: CGFloat = 1
    @Published var fechados = false

    private func esperar(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    func animar() async {
        x = 300; y = 0; sx = 1; sy = 1; fechados = false
        for alvo: CGFloat in [200, 100, 0] { await salto(para: alvo) }   // entra aos saltinhos
        await esperar(0.5)
        await piscar()
        await esperar(0.9)                                               // pára
        await piscar()
        await esperar(0.25)
        await piscar()
        await esperar(0.7)
        for alvo: CGFloat in [100, 200, 320] { await salto(para: alvo) }  // sai pela direita
    }

    private func salto(para alvo: CGFloat) async {
        withAnimation(.easeOut(duration: 0.08)) { sy = 0.82; sx = 1.12 }             // agacha
        await esperar(0.08)
        let meio = (x + alvo) / 2
        withAnimation(.easeOut(duration: 0.2)) { x = meio; y = -42; sy = 1.1; sx = 0.93 }   // sobe
        await esperar(0.2)
        withAnimation(.easeIn(duration: 0.2)) { x = alvo; y = 0; sy = 1; sx = 1 }    // desce
        await esperar(0.2)
        withAnimation(.easeOut(duration: 0.07)) { sy = 0.84; sx = 1.1 }              // aterra
        await esperar(0.07)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { sy = 1; sx = 1 }
        await esperar(0.14)
    }

    private func piscar() async {
        fechados = true
        await esperar(0.13)
        fechados = false
    }
}

struct VistaMascote: View {
    @ObservedObject var e: EstadoMascote
    static let aberto = Bundle.main.url(forResource: "mascote", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    static let fechado = Bundle.main.url(forResource: "mascote-piscar", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // sombra no chão: mais pequena quando está no ar
            Ellipse().fill(.black.opacity(0.28))
                .frame(width: 62 * (1 + e.y / 120), height: 10)
                .blur(radius: 3)
                .offset(x: e.x, y: 4)
            if let img = (e.fechados ? Self.fechado : Self.aberto) ?? Self.aberto {
                Image(nsImage: img)
                    .resizable().interpolation(.high)
                    .frame(width: 78, height: 90)
                    .scaleEffect(x: e.sx, y: e.sy, anchor: .bottom)
                    .offset(x: e.x, y: e.y)
            }
        }
        .padding(.trailing, 28).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

@MainActor
final class Mascote {
    static let shared = Mascote()
    var podeAparecer: () -> Bool = { true }
    var minutos: () -> Double = { 5 }

    private var painel: NSPanel?
    private let e = EstadoMascote()
    private var timer: Timer?
    private var aDecorrer = false

    func iniciar() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in Mascote.shared.talvez() }
        }
    }

    private var ultima = Date()

    private func talvez() {
        guard Date().timeIntervalSince(ultima) >= minutos() * 60 else { return }
        ultima = Date()
        if podeAparecer() { mostrar() }
    }

    /// Mostra já (também usado pelo botão «Ver agora»)
    func mostrar() {
        guard !aDecorrer, let ecra = NSScreen.main else { return }
        aDecorrer = true
        let tam = NSSize(width: 420, height: 170)
        let vf = ecra.visibleFrame                       // acima da Dock
        let p = painel ?? criarPainel(tam)
        p.setFrame(.init(x: vf.maxX - tam.width, y: vf.minY, width: tam.width, height: tam.height), display: true)
        p.orderFrontRegardless()
        Task {
            await e.animar()
            p.orderOut(nil)
            aDecorrer = false
        }
    }

    private func criarPainel(_ tam: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: .init(origin: .zero, size: tam),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: VistaMascote(e: e))
        host.frame = .init(origin: .zero, size: tam)
        p.contentView = host
        painel = p
        return p
    }
}
