import SwiftUI
import SwiftData
import AppKit

@Observable
final class AppState: @unchecked Sendable {
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
        let storageMode = UserDefaults.standard.string(forKey: SettingsKey.storageMode) ?? "local"
        do {
            self.modelContainer = try AppState.makeModelContainer(storageMode: storageMode)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }

        self.cryptoEngine = CryptoEngine()
        self.authService = AuthService(cryptoEngine: cryptoEngine)

        self.lockState = authService.isSetUp ? .locked : .needsSetup
        setupLockObservers()

        if storageMode == "icloud" {
            setupRemoteChangeObserver()
        }
    }

    static func makeModelContainer(storageMode: String) throws -> ModelContainer {
        let schema = Schema([Vault.self, Item.self])

        let config: ModelConfiguration
        if storageMode == "icloud" {
            config = ModelConfiguration(
                "OnePasshole",
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
        } else {
            config = ModelConfiguration(
                "OnePasshole",
                schema: schema,
                isStoredInMemoryOnly: false
            )
        }

        return try ModelContainer(for: schema, configurations: [config])
    }

    private var autoLockTimer: Timer?

    func lock() {
        lockState = .locked
        selectedVault = nil
        selectedItem = nil
        cryptoEngine.clearKeys()
    }

    func unlock(with masterKey: SymmetricKeyData) {
        cryptoEngine.setMasterKey(masterKey)
        lockState = .unlocked
        resetAutoLockTimer()
    }

    private func setupLockObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard UserDefaults.standard.bool(forKey: SettingsKey.lockOnSleep) else { return }
            Task { @MainActor in self?.lock() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard UserDefaults.standard.bool(forKey: SettingsKey.lockOnScreenSaver) else { return }
            Task { @MainActor in self?.lock() }
        }
    }

    private func setupRemoteChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.validateSelection()
            }
        }
    }

    private func validateSelection() {
        if let item = selectedItem, item.isDeleted {
            selectedItem = nil
        }
        if let vault = selectedVault, vault.isDeleted {
            selectedVault = nil
            selectedItem = nil
        }
    }

    private func resetAutoLockTimer() {
        autoLockTimer?.invalidate()
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.autoLockTimeout)
        guard minutes > 0 else { return }
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }
}
