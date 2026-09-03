import SwiftUI
import SwiftData
import AppKit

@Observable
@MainActor
final class AppState: @unchecked Sendable {
    enum LockState {
        case locked
        case unlocked
        case needsSetup
    }

    var lockState: LockState
    var selectedVault: SelectedVault?
    var selectedItem: SelectedItem?
    var opvaultSessions: [UUID: OPVaultSession] = [:]

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

        if authService.isSetUp {
            self.lockState = .locked
        } else {
            // No native master password was ever created — this is only "not set up yet"
            // if there's also no OPVault connection to use as the primary vault (see
            // `isOPVaultPrimary`). If one exists, its own password is the front door.
            let hasOPVaultConnection = ((try? modelContainer.mainContext.fetch(FetchDescriptor<OPVaultConnection>())) ?? []).isEmpty == false
            self.lockState = hasOPVaultConnection ? .locked : .needsSetup
        }
        setupLockObservers()

        if storageMode == "icloud" {
            setupRemoteChangeObserver()
        }
    }

    static func makeModelContainer(storageMode: String) throws -> ModelContainer {
        let schema = Schema([Vault.self, Item.self, OPVaultConnection.self])

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

    /// True when there is no separate 1passhole master password at all — the app was set
    /// up by connecting an existing OPVault vault, whose own password is the sole thing
    /// that unlocks both that vault and the app itself (see `OPVaultSession.derivedNativeMasterKey`).
    var isOPVaultPrimary: Bool { !authService.isSetUp }

    /// The OPVault connection to prompt for on the lock screen when `isOPVaultPrimary`.
    /// There's normally exactly one in this mode (the one chosen during setup).
    func primaryOPVaultConnection() -> OPVaultConnection? {
        let descriptor = FetchDescriptor<OPVaultConnection>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? modelContainer.mainContext.fetch(descriptor))?.first
    }

    private var autoLockTimer: Timer?

    func lock() {
        lockState = .locked
        selectedVault = nil
        selectedItem = nil
        cryptoEngine.clearKeys()
        opvaultSessions.removeAll()
    }

    func unlock(with masterKey: SymmetricKeyData) {
        cryptoEngine.setMasterKey(masterKey)
        lockState = .unlocked
        resetAutoLockTimer()

        // Setup only ever creates credentials, never the first vault itself (see
        // SetupView) — the very first successful native unlock creates the default
        // vault, so there's exactly one unlock code path regardless of how the app was
        // set up. Not done in OPVault-primary mode: choosing "1Password Vault" at setup
        // means the user doesn't want a native vault created for them too.
        if !isOPVaultPrimary {
            ensureDefaultVaultExists()
        }

        // There's no sidebar to pick a vault from anymore (vault management lives in
        // Settings) — land somewhere useful by default instead of an empty "no vault"
        // state, same as the old sidebar's onAppear used to.
        if selectedVault == nil {
            selectedVault = defaultVaultSelection()
        }
    }

    private func defaultVaultSelection() -> SelectedVault? {
        if isOPVaultPrimary, let connection = primaryOPVaultConnection() {
            return .opvault(connection)
        }
        let descriptor = FetchDescriptor<Vault>(sortBy: [SortDescriptor(\.name)])
        if let vault = (try? modelContainer.mainContext.fetch(descriptor))?.first {
            return .native(vault)
        }
        return nil
    }

    private func ensureDefaultVaultExists() {
        let hasVaults = ((try? modelContainer.mainContext.fetch(FetchDescriptor<Vault>())) ?? []).isEmpty == false
        guard !hasVaults else { return }
        let vaultService = VaultService(modelContext: modelContainer.mainContext, crypto: cryptoEngine)
        _ = try? vaultService.createVault(name: "Personal")
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
        if case .native(let item) = selectedItem, item.isDeleted {
            selectedItem = nil
        }
        if case .native(let vault) = selectedVault, vault.isDeleted {
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
