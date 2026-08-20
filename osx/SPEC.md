# 1passhole — Project Specification

Native macOS password manager, heavily inspired by 1Password. Open-source, auditable, zero-knowledge encryption.

## Design Decisions

- **Framework**: SwiftUI + AppKit, macOS only (14.0+)
- **Language**: Swift 6 (strict concurrency)
- **Persistence**: SwiftData (encrypted blobs stored as `Data`)
- **Encryption**: AES-256-GCM via CryptoKit
- **Key derivation**: Argon2id via `Argon2Swift` (3 iterations, 64 MB memory, 4 parallelism, 32-byte output)
- **Biometrics**: Touch ID via LocalAuthentication + Secure Enclave
- **Sync**: iCloud via CloudKit (planned)
- **Project generation**: xcodegen (`project.yml`)
- **Master password minimum**: 8 characters
- **Clipboard auto-clear**: 5 minutes (configurable via Settings)
- **Item create/edit**: Inline in the detail panel (no modal sheets)
- **Detail view**: 1Password-style card-based layout
- **Settings**: 1Password-style sidebar settings window (Cmd+,) with General, Vault, Appearance tabs
- **Preferences storage**: `@AppStorage` (UserDefaults) for all user preferences

## Architecture

### Key Hierarchy (3-tier, zero-knowledge)

```
Master Password
    → Argon2id (salt stored in Keychain)
    → Master Key (SymmetricKey, 256-bit)
        → encrypts each Vault Key (per-vault, AES-256-GCM)
            → encrypts Item Payloads (per-item, AES-256-GCM)
```

- Master key never persisted to disk; derived on unlock
- Vault keys stored as `encryptedKey: Data` on each Vault model
- Item payloads stored as `encryptedPayload: Data` on each Item model
- Verification hash (HKDF-SHA256) stored in Keychain to verify password without storing it

### Data Models

**Vault** (`@Model`)
- `id: UUID`, `name: String`, `iconName: String`
- `encryptedKey: Data` — vault key encrypted with master key
- `createdAt: Date`, `modifiedAt: Date`
- Relationship to `[Item]`

**Item** (`@Model`)
- `id: UUID`, `title: String`, `type: ItemType`
- `vault: Vault?` (relationship)
- `encryptedPayload: Data` — JSON-encoded `ItemPayload` encrypted with vault key
- `createdAt: Date`, `modifiedAt: Date`

**ItemType** — `login`, `creditCard`, `identity`, `secureNote`

**ItemPayload** (Codable, never persisted directly)
- `fields: [ItemField]`, `notes: String?`

**ItemField** (Codable, Identifiable)
- `label`, `value`, `type: FieldType`, `isConcealed: Bool`

**FieldType** — `text`, `password`, `url`, `email`, `totp`, `phone`, `date`, `monthYear`, `creditCardNumber`

### Services

- **AuthService** — Master password setup/verify via Keychain, Touch ID enrollment via Secure Enclave
- **VaultService** — CRUD for vaults and items, encryption/decryption through CryptoEngine
- **ClipboardService** — Copy to pasteboard with 5-minute auto-clear
- **PasswordGenerator** — Random passwords (configurable charset/length) and passphrases (word list, separator, capitalize)
- **CryptoEngine** — AES-256-GCM encrypt/decrypt, vault key management, verification hash

### UI Structure

3-column `NavigationSplitView`:
1. **Sidebar** — Vault list (create/delete/rename)
2. **Item List** — Filtered by vault and search text
3. **Detail Panel** — Switches between viewing, editing, creating via `DetailMode` enum

**Keyboard Shortcuts**:
- `Cmd+N` — Create new item
- `Cmd+F` — Focus search (native `.searchable` behavior)

**Lock States**: `locked` → `unlocked` → `needsSetup` (routed in ContentView)

## File Structure

```
Sources/
  App/
    OnePassholeApp.swift      — SwiftUI lifecycle, ModelContainer, Settings scene
    AppState.swift            — Central @Observable state, lock management, lock observers
    ContentView.swift         — Routes lock states
    SettingsKey.swift          — UserDefaults key constants
  Crypto/
    CryptoEngine.swift        — AES-256-GCM, key hierarchy ops
    KeyDerivation.swift       — Argon2id wrapper
    SymmetricKeyData.swift    — Sendable SymmetricKey wrapper
  Models/
    Vault.swift               — SwiftData vault model
    Item.swift                — SwiftData item model + payload types
    ItemTemplates.swift       — Default field templates per item type
  Services/
    AuthService.swift         — Keychain + Touch ID
    VaultService.swift        — Vault/item CRUD with encryption
    ClipboardService.swift    — Pasteboard + auto-clear
    PasswordGenerator.swift   — Random + passphrase generation
  Views/
    Main/
      MainView.swift          — 3-column NavigationSplitView
      SidebarView.swift       — Vault sidebar
      ItemListView.swift      — Item list + search
    Items/
      ItemDetailView.swift    — 1Password-style card detail
      ItemEditView.swift      — Inline edit/create form
    Unlock/
      SetupView.swift         — Master password setup + Touch ID enrollment
      UnlockView.swift        — Unlock with password or Touch ID
    Settings/
      SettingsView.swift        — 1Password-style sidebar settings window
      GeneralSettingsTab.swift  — Clipboard, lock-on-sleep, auto-lock
      VaultSettingsTab.swift    — Storage location, Touch ID toggle
      AppearanceSettingsTab.swift — Theme, icon size, compact mode
    Generator/
      PasswordGeneratorView.swift — Password/passphrase generator UI
Tests/
  CryptoEngineTests.swift     — Crypto roundtrip, vault key, verification hash tests
Resources/
  Info.plist
  OnePasshole.entitlements
  Assets.xcassets/
```

## Dependencies

| Package | Source | Branch |
|---------|--------|--------|
| Argon2Swift | github.com/tmthecoder/Argon2Swift | main |

## Build

```bash
# Generate Xcode project
xcodegen generate

# Build
xcodebuild -project OnePasshole.xcodeproj -scheme OnePasshole -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Output: `1passhole.app` (set via `productName: 1passhole` in project.yml)

## Feature Roadmap

### Phase 1 — Core (Done)
- [x] Master password setup with Argon2id key derivation
- [x] AES-256-GCM encryption with 3-tier key hierarchy
- [x] Touch ID unlock via Secure Enclave
- [x] Vault CRUD (create, rename, delete)
- [x] Item CRUD (login, credit card, identity, secure note)
- [x] Inline item create/edit in detail panel
- [x] 1Password-style card detail view (hover copy/reveal)
- [x] Search with Cmd+F
- [x] Cmd+N new item shortcut
- [x] Password generator (random + passphrase)
- [x] Clipboard auto-clear (configurable, default 5 minutes)
- [x] Verification hash for password check without storing password
- [x] Settings window (Cmd+,) with General, Vault, Appearance tabs
- [x] Lock on sleep / screen saver (configurable)
- [x] Auto-lock idle timer (configurable)
- [x] Touch ID enroll/unenroll from Settings
- [x] Theme picker (System / Light / Dark)
- [x] Compact mode and sidebar icon size settings
- [x] iCloud sync via CloudKit (SwiftData automatic, toggle in Settings, restart required)

### Phase 2 — Polish
- [ ] Full EFF diceware wordlist (load from resource bundle)
- [ ] Password strength meter on setup
- [ ] Item type icons in list view
- [ ] Sorting/filtering options in item list
- [ ] Confirmation dialogs for destructive actions (delete vault/item)
- [ ] Error handling polish

### Phase 3 — Sync & Platform
- [x] iCloud sync via CloudKit
- [ ] TOTP authenticator (time-based one-time passwords)
- [ ] System autofill (Credential Provider extension)
- [ ] Import/export (1Password CSV, Bitwarden JSON)

### Phase 4 — Power Features
- [ ] Menu bar agent (NSStatusItem) with quick access
- [ ] Global hotkey for quick search
- [ ] Auto-lock on idle/sleep (basic timer done, needs activity reset)
- [ ] Secure notes with rich text
- [ ] Custom field types
- [ ] Multiple vaults with distinct icons

## Explicitly Excluded

These features are intentionally out of scope:
- Enterprise/team features
- Browser extension
- Travel mode
- Masked email / email aliases
- Tags and favorites
- Drag-and-drop items between vaults
- Watchtower / breach checking
