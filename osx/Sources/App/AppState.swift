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

    /// One entry in the recently-switched-to vault list, persisted across launches.
    /// Stores just enough to re-resolve against the live `Vault`/`OPVaultConnection`
    /// query results — the referenced object may since have been deleted, in which case
    /// the entry is silently skipped when displaying the list.
    struct RecentVaultRef: Codable, Equatable {
        enum Kind: String, Codable { case native, opvault }
        let kind: Kind
        let id: UUID

        init(kind: Kind, id: UUID) {
            self.kind = kind
            self.id = id
        }

        init(_ selection: SelectedVault) {
            switch selection {
            case .native(let vault): self.init(kind: .native, id: vault.id)
            case .opvault(let connection): self.init(kind: .opvault, id: connection.id)
            }
        }

        /// String form stored under `SettingsKey.defaultVault`, e.g. `"native:<uuid>"`.
        var settingsValue: String { "\(kind.rawValue):\(id.uuidString)" }

        init?(settingsValue: String) {
            let parts = settingsValue.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let kind = Kind(rawValue: parts[0]),
                  let id = UUID(uuidString: parts[1])
            else { return nil }
            self.init(kind: kind, id: id)
        }
    }

    var lockState: LockState
    var selectedVault: SelectedVault?
    var selectedItem: SelectedItem?
    var opvaultSessions: [UUID: OPVaultSession] = [:]
    /// Connected OPVaults whose password didn't match the master password at the last
    /// password unlock. They still open via their own prompt; Settings offers to change
    /// the master password to match. Not persisted — re-learned on every password unlock.
    private(set) var opvaultPasswordMismatches: Set<UUID> = []
    private(set) var recentVaults: [RecentVaultRef] = []

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
        loadRecentVaults()

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
        opvaultPasswordMismatches.removeAll()
    }

    // MARK: - One password for everything

    /// Unlocks the app and every connected OPVault with one password. Connected vaults
    /// are expected to share it (enforced on connect); any that don't are recorded in
    /// `opvaultPasswordMismatches` and keep their own prompt.
    func unlock(password: String) throws {
        let masterKey: SymmetricKeyData
        var sessions: [UUID: OPVaultSession] = [:]
        if isOPVaultPrimary {
            // The primary OPVault's password *is* the master password in this mode.
            guard let primary = primaryOPVaultConnection() else {
                throw OPVaultServiceError.itemNotFound
            }
            let session = try OPVaultService.unlock(connection: primary, password: password)
            masterKey = session.derivedNativeMasterKey()
            sessions[primary.id] = session
        } else {
            masterKey = try authService.unlock(password: password)
        }

        var mismatches: Set<UUID> = []
        for connection in allOPVaultConnections() where sessions[connection.id] == nil {
            do {
                sessions[connection.id] = try OPVaultService.unlock(connection: connection, password: password)
            } catch OPVaultServiceError.wrongPassword {
                mismatches.insert(connection.id)
            } catch {
                // Folder unreachable (e.g. Dropbox not mounted) — not a password problem;
                // its own prompt will surface the real error when opened.
            }
        }

        // Sessions go in before `unlock(with:)` flips the lock state, so an OPVault
        // default vault opens straight into its items rather than flashing a prompt.
        opvaultSessions = sessions
        opvaultPasswordMismatches = mismatches
        unlock(with: masterKey)
        refreshTouchIDEnrollment()
    }

    /// Touch ID counterpart of `unlock(password:)`: reopens each OPVault from the keys
    /// saved at enrollment. One whose keys are missing or stale keeps its password prompt.
    func unlock(withTouchID bundle: BiometricUnlockBundle) {
        var sessions: [UUID: OPVaultSession] = [:]
        for connection in allOPVaultConnections() {
            guard let keys = bundle.opvaultKeys(for: connection.id) else { continue }
            sessions[connection.id] = try? OPVaultService.openSession(connection: connection, keys: keys)
        }
        opvaultSessions = sessions
        unlock(with: SymmetricKeyData(data: bundle.masterKey))
    }

    /// Adds a newly connected OPVault (already unlocked with the master password) and
    /// switches to it.
    func addOPVaultConnection(_ connection: OPVaultConnection, session: OPVaultSession) throws {
        let context = modelContainer.mainContext
        if connection.modelContext == nil {
            context.insert(connection)
        }
        try context.save()
        opvaultSessions[connection.id] = session
        opvaultPasswordMismatches.remove(connection.id)
        refreshTouchIDEnrollment()
        switchVault(to: .opvault(connection))
    }

    func removeOPVaultConnection(_ connection: OPVaultConnection) {
        if selectedVault == .opvault(connection) {
            selectedVault = nil
        }
        opvaultSessions.removeValue(forKey: connection.id)
        opvaultPasswordMismatches.remove(connection.id)
        modelContainer.mainContext.delete(connection)
        try? modelContainer.mainContext.save()
        refreshTouchIDEnrollment()
    }

    /// Records a session opened from an OPVault's own prompt (a mismatched password),
    /// and includes its keys in the Touch ID bundle.
    func didUnlockOPVaultSeparately(_ connection: OPVaultConnection, session: OPVaultSession) {
        opvaultSessions[connection.id] = session
        refreshTouchIDEnrollment()
    }

    /// True when `password` is the app's master password (native mode) or the primary
    /// OPVault's password (OPVault-primary mode). Never stores anything.
    func isMasterPassword(_ password: String) -> Bool {
        if isOPVaultPrimary {
            guard let primary = primaryOPVaultConnection(),
                  let session = try? OPVaultService.unlock(connection: primary, password: password),
                  let current = try? cryptoEngine.getMasterKeyData()
            else { return false }
            return session.derivedNativeMasterKey().data == current.data
        }
        return (try? authService.unlock(password: password)) != nil
    }

    /// Changes the native master password, re-wrapping every vault key under the new
    /// master key so no data is lost, then refreshes Touch ID. Requires the current
    /// password as confirmation. Rolls back the Keychain credentials if saving the
    /// re-wrapped vault keys fails, so the store and the password never disagree.
    func changeMasterPassword(current: String, to newPassword: String) throws {
        guard !isOPVaultPrimary else { throw MasterPasswordChangeError.opvaultPrimary }
        let oldKey = try authService.unlock(password: current)
        guard let oldCredentials = authService.currentCredentials() else { throw AuthError.notSetUp }
        let (newKey, newCredentials) = try authService.deriveCredentials(password: newPassword)

        let context = modelContainer.mainContext
        let vaults = try context.fetch(FetchDescriptor<Vault>())
        let rewrapped: [(Vault, Data)] = try vaults.map { vault in
            let vaultKey = try cryptoEngine.decrypt(vault.encryptedKey, using: oldKey.symmetricKey)
            return (vault, try cryptoEngine.encrypt(vaultKey, using: newKey.symmetricKey))
        }

        try authService.storeCredentials(newCredentials)
        do {
            for (vault, encryptedKey) in rewrapped {
                vault.encryptedKey = encryptedKey
                vault.modifiedAt = .now
            }
            try context.save()
        } catch {
            context.rollback()
            try? authService.storeCredentials(oldCredentials)
            throw error
        }

        cryptoEngine.setMasterKey(newKey)
        refreshTouchIDEnrollment()
    }

    /// Enrolls (or re-enrolls) Touch ID with the current master key plus the keys of
    /// every open OPVault session.
    func enrollTouchID() throws {
        let masterKey = try cryptoEngine.getMasterKeyData()
        try authService.enrollTouchID(
            masterKey: masterKey,
            opvaultKeys: opvaultSessions.mapValues(\.keys)
        )
    }

    /// Keeps the Touch ID item in step with the master key and open OPVault sessions.
    /// A no-op when Touch ID isn't enrolled (it never enrolls on its own).
    private func refreshTouchIDEnrollment() {
        guard authService.isTouchIDEnrolled, cryptoEngine.isUnlocked else { return }
        try? enrollTouchID()
    }

    private func allOPVaultConnections() -> [OPVaultConnection] {
        (try? modelContainer.mainContext.fetch(FetchDescriptor<OPVaultConnection>())) ?? []
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

    /// The one place `selectedVault` should be changed from. OPVault sessions stay open
    /// across switches — like native vault keys, they live until the app locks, since one
    /// master password unlocks everything. Safe to call while the app itself is still
    /// locked: it only touches selection state, never the crypto engine.
    func switchVault(to newSelection: SelectedVault?) {
        guard newSelection != selectedVault else { return }
        selectedVault = newSelection
        selectedItem = nil
        recordRecentVault(newSelection)
    }

    private func recordRecentVault(_ selection: SelectedVault?) {
        guard let selection else { return }
        let ref = RecentVaultRef(selection)
        recentVaults.removeAll { $0 == ref }
        recentVaults.insert(ref, at: 0)
        if recentVaults.count > 5 {
            recentVaults.removeLast(recentVaults.count - 5)
        }
        if let data = try? JSONEncoder().encode(recentVaults) {
            UserDefaults.standard.set(data, forKey: SettingsKey.recentVaults)
        }
    }

    private func loadRecentVaults() {
        guard let data = UserDefaults.standard.data(forKey: SettingsKey.recentVaults),
              let decoded = try? JSONDecoder().decode([RecentVaultRef].self, from: data)
        else { return }
        recentVaults = decoded
    }

    /// Values for `SettingsKey.defaultVault` besides a specific vault reference
    /// (`"native:<uuid>"` / `"opvault:<uuid>"`, see `RecentVaultRef.settingsValue`).
    enum DefaultVaultSetting {
        static let automatic = ""
        static let lastUsed = "lastUsed"
    }

    /// Resolves a persisted vault reference against the live store — nil if the vault
    /// or connection has since been deleted.
    private func resolve(_ ref: RecentVaultRef) -> SelectedVault? {
        let context = modelContainer.mainContext
        let id = ref.id
        switch ref.kind {
        case .native:
            let descriptor = FetchDescriptor<Vault>(predicate: #Predicate { $0.id == id })
            return (try? context.fetch(descriptor))?.first.map(SelectedVault.native)
        case .opvault:
            let descriptor = FetchDescriptor<OPVaultConnection>(predicate: #Predicate { $0.id == id })
            return (try? context.fetch(descriptor))?.first.map(SelectedVault.opvault)
        }
    }

    /// The vault to land on after unlocking: the user's explicit choice from Settings
    /// (a specific vault, or the last-used one) when it still resolves, otherwise the
    /// automatic fallback below.
    private func defaultVaultSelection() -> SelectedVault? {
        let setting = UserDefaults.standard.string(forKey: SettingsKey.defaultVault) ?? DefaultVaultSetting.automatic
        if setting == DefaultVaultSetting.lastUsed {
            if let selection = recentVaults.lazy.compactMap({ self.resolve($0) }).first {
                return selection
            }
        } else if let ref = RecentVaultRef(settingsValue: setting), let selection = resolve(ref) {
            return selection
        }
        return automaticVaultSelection()
    }

    private func automaticVaultSelection() -> SelectedVault? {
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

enum MasterPasswordChangeError: LocalizedError {
    case opvaultPrimary

    var errorDescription: String? {
        switch self {
        case .opvaultPrimary:
            "Your master password is your primary 1Password vault's password — change it in 1Password."
        }
    }
}
