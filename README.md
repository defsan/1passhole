# 1Passhole

A native macOS password manager, heavily inspired by 1Password. Open-source, auditable, and built on zero-knowledge encryption.
<img width="1203" height="901" alt="image" src="https://github.com/user-attachments/assets/94233833-3219-44dc-afba-c20b64f33d54" />

## Download

Prebuilt, unsigned macOS builds are published automatically:

- **Latest build from `main`** (updated on every push): [`latest-main` release](https://github.com/defsan/1passhole/releases/tag/latest-main) — download `1passhole-macos.zip`.
- **Tagged versions**: see the [Releases page](https://github.com/defsan/1passhole/releases) for numbered `vX.Y.Z` releases, once available.

The app isn't signed or notarized, so Gatekeeper will refuse a plain double-click on first launch. After unzipping, either:

- Right-click `1passhole.app` → **Open**, then confirm in the dialog that appears, or
- Run `xattr -cr /path/to/1passhole.app` in Terminal, then launch normally.

You only need to do this once per download. Prefer to build it yourself? See [Building](#building) below.

## What it does

1Passhole stores logins, credit cards, identities, and secure notes in encrypted vaults, protected by a single master password. It never stores your master password — only a verification hash — and every vault/item is encrypted client-side before it touches disk, so the app (and anyone with access to its storage) can't read your data without the key.

Key capabilities:

- **Vaults & items** — organize logins, credit cards, identities, and secure notes into multiple vaults; full CRUD with inline create/edit in the detail panel.
- **Zero-knowledge encryption** — a 3-tier key hierarchy (master password → master key → per-vault key → per-item payload) using Argon2id for key derivation and AES-256-GCM for encryption.
- **Touch ID unlock** — biometric unlock via Secure Enclave, enrollable from Settings.
- **Password generator** — random passwords and diceware-style passphrases with configurable options.
- **Clipboard auto-clear** — copied secrets are wiped from the pasteboard after a configurable timeout (default 5 minutes).
- **iCloud sync** — optional sync across devices via CloudKit (SwiftData-backed).
- **Auto-lock** — lock on sleep/screensaver and on idle timeout, both configurable.
- **1Password-style UI** — 3-column `NavigationSplitView` (vault sidebar, item list with search, card-based detail panel), plus a sidebar-style Settings window (`Cmd+,`).

## How it works

```
Master Password
    → Argon2id (salt stored in Keychain)
    → Master Key (SymmetricKey, 256-bit)
        → encrypts each Vault Key (per-vault, AES-256-GCM)
            → encrypts Item Payloads (per-item, AES-256-GCM)
```

The master key is derived on unlock and never persisted. Vault keys and item payloads are stored as encrypted `Data` blobs via SwiftData. A password verification hash (HKDF-SHA256) is kept in the Keychain so the app can check your master password without ever storing it.

## Tech stack

- Swift 6 (strict concurrency), SwiftUI + AppKit — macOS 14.0+
- SwiftData for persistence, CloudKit for optional iCloud sync
- CryptoKit for AES-256-GCM, [Argon2Swift](https://github.com/tmthecoder/Argon2Swift) for Argon2id key derivation
- LocalAuthentication + Secure Enclave for Touch ID
- Project generated with [xcodegen](https://github.com/yonaskolb/XcodeGen) (`project.yml`)

## Project layout

The macOS app lives under [`osx/`](osx/); see [`osx/SPEC.md`](osx/SPEC.md) for the full architecture, data model, and feature roadmap.

```
osx/
  Sources/
    App/        — SwiftUI app lifecycle, central app state, lock routing
    Crypto/     — AES-256-GCM engine, Argon2id key derivation
    Models/     — SwiftData models (Vault, Item, item payloads/fields)
    Services/   — Auth (Keychain/Touch ID), vault/item CRUD, clipboard, password generation
    Views/      — Main window, item list/detail, unlock/setup, settings, password generator
  Tests/        — Crypto engine unit tests
  Resources/    — Info.plist, entitlements, assets
  project.yml   — xcodegen project definition
```

## Building

Prebuilt binaries are available above under [Download](#download); the steps below build 1Passhole from source.

```bash
cd osx
./build.sh          # Debug build (add "Release" for a release build)
```

This regenerates the Xcode project via `xcodegen` and builds unsigned into `osx/build/Build/Products/<config>/1passhole.app`. CI (`.github/workflows/build.yml`) runs the same script, so local and CI builds always match.

## Status

Core functionality (vaults, items, encryption, Touch ID, password generator, settings, iCloud sync) is done. Planned work includes a full EFF diceware wordlist, TOTP support, system autofill, and CSV/JSON import-export — see the roadmap in [`osx/SPEC.md`](osx/SPEC.md) for details.

**Explicitly out of scope:** enterprise/team features, browser extension, travel mode, masked emails, tags/favorites, drag-and-drop between vaults, and breach checking.
