import SwiftUI
import SwiftData

@Observable
final class AppState {
    enum LockState {
        case locked
        case unlocked
        case needsSetup
    }

    var lockState: LockState
    var selectedVault: Vault?
    var selectedItem: Item?

    let modelContainer: ModelContainer
    let cryptoEngine: CryptoEngine
    let authService: AuthService

    init() {
        let schema = Schema([Vault.self, Item.self])
        let config = ModelConfiguration(
            "OnePasshole",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create model container: \(error)")
        }

        self.cryptoEngine = CryptoEngine()
        self.authService = AuthService(cryptoEngine: cryptoEngine)

        self.lockState = authService.isSetUp ? .locked : .needsSetup
    }

    func lock() {
        lockState = .locked
        selectedVault = nil
        selectedItem = nil
        cryptoEngine.clearKeys()
    }

    func unlock(with masterKey: SymmetricKeyData) {
        cryptoEngine.setMasterKey(masterKey)
        lockState = .unlocked
    }
}
