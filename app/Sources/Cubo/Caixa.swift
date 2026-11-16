import Combine

/// Substitui o @State (cuja macro só existe com o Xcode completo).
final class Caixa<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}
