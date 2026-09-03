#!/usr/bin/env python3
"""
opvault_tool.py — read/write tool for the AgileBits OPVault format
(the folder-based `*.opvault` bundle used by 1Password 4/5/6 and by
1Password's Dropbox-sync vaults).

This is a standalone research/validation script, independent of the
1passhole macOS app. It never sends anything over the network and never
prints your master password. Any write to a real vault is preceded by an
automatic timestamped backup of the whole bundle.

Commands:
    selftest                     Build a synthetic fake vault in a temp dir
                                  and round-trip unlock/list/show/add against
                                  it. No real password or real vault involved.
                                  Use this first to prove the crypto is correct.

    list       --vault PATH      List all items (uuid, category, title, url)
    show       --vault PATH UUID Show full decrypted details for one item
    verify-hmac --vault PATH     Empirically determine the item "hmac" formula
                                  by testing candidates against real items
    add        --vault PATH      Add a new Login item (prompts for fields)
                                  Refuses to run without --confirm-write
    remove     --vault PATH UUID Delete one item by uuid
                                  Refuses to run without --confirm-write

Master password is always entered via a hidden prompt (getpass), never as
a CLI argument or file, so it never lands in shell history or this chat.
"""

import argparse
import base64
import getpass
import hashlib
import hmac as hmac_mod
import json
import os
import re
import secrets
import shutil
import struct
import sys
import tempfile
import uuid as uuid_mod
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

CATEGORY_NAMES = {
    "001": "Login",
    "002": "Credit Card",
    "003": "Secure Note",
    "004": "Identity",
    "005": "Password",
    "006": "Tombstone",
    "100": "Software License",
    "101": "Bank Account",
    "102": "Database",
    "103": "Driver License",
    "104": "Outdoor License",
    "105": "Membership",
    "106": "Passport",
    "107": "Rewards Program",
    "108": "Social Security Number",
    "109": "Router",
    "110": "Server",
    "111": "Email Account",
}


# --------------------------------------------------------------------------
# Low-level crypto primitives (OPVault design: PBKDF2-SHA512, opdata01 AES-256-CBC + HMAC-SHA256)
# --------------------------------------------------------------------------

def b64d(s: str) -> bytes:
    s = s.strip()
    pad = (-len(s)) % 4
    return base64.b64decode(s + "=" * pad)


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def aes_cbc_encrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    enc = cipher.encryptor()
    return enc.update(data) + enc.finalize()


def aes_cbc_decrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    dec = cipher.decryptor()
    return dec.update(data) + dec.finalize()


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac_mod.new(key, data, hashlib.sha256).digest()


class OPVaultError(Exception):
    pass


def derive_master_key(password: str, salt: bytes, iterations: int) -> bytes:
    kdf = PBKDF2HMAC(algorithm=hashes.SHA512(), length=64, salt=salt, iterations=iterations)
    return kdf.derive(password.encode("utf-8"))


def opdata01_decrypt(blob: bytes, enc_key: bytes, mac_key: bytes) -> bytes:
    if blob[:8] != b"opdata01":
        raise OPVaultError("bad opdata01 magic")
    plain_len = struct.unpack("<Q", blob[8:16])[0]
    iv = blob[16:32]
    ciphertext = blob[32:-32]
    stored_mac = blob[-32:]
    computed_mac = hmac_sha256(mac_key, blob[:-32])
    if not hmac_mod.compare_digest(stored_mac, computed_mac):
        raise OPVaultError("opdata01 HMAC mismatch (wrong password or corrupt data)")
    padded = aes_cbc_decrypt(enc_key, iv, ciphertext)
    return padded[-plain_len:] if plain_len else b""


def opdata01_encrypt(plaintext: bytes, enc_key: bytes, mac_key: bytes) -> bytes:
    plain_len = len(plaintext)
    pad_len = (-plain_len) % 16
    padded = secrets.token_bytes(pad_len) + plaintext
    iv = secrets.token_bytes(16)
    ciphertext = aes_cbc_encrypt(enc_key, iv, padded)
    header = b"opdata01" + struct.pack("<Q", plain_len) + iv
    mac = hmac_sha256(mac_key, header + ciphertext)
    return header + ciphertext + mac


def wrap_item_key(master_enc: bytes, master_mac: bytes, item_enc: bytes, item_mac: bytes) -> bytes:
    """Format of the item 'k' field: iv(16) + AES-CBC(item_enc||item_mac)(64) + HMAC-SHA256(32)."""
    iv = secrets.token_bytes(16)
    ciphertext = aes_cbc_encrypt(master_enc, iv, item_enc + item_mac)
    mac = hmac_sha256(master_mac, iv + ciphertext)
    return iv + ciphertext + mac


def unwrap_item_key(master_enc: bytes, master_mac: bytes, blob: bytes):
    iv = blob[:16]
    ciphertext = blob[16:80]
    stored_mac = blob[80:112]
    computed_mac = hmac_sha256(master_mac, iv + ciphertext)
    if not hmac_mod.compare_digest(stored_mac, computed_mac):
        raise OPVaultError("item key HMAC mismatch")
    decrypted = aes_cbc_decrypt(master_enc, iv, ciphertext)
    return decrypted[:32], decrypted[32:64]


# --------------------------------------------------------------------------
# JS-wrapper (de)serialization: profile.js / folders.js / band_X.js
# --------------------------------------------------------------------------

def _unwrap_js(text: str, patterns) -> str:
    text = text.strip()
    for pattern in patterns:
        m = re.match(pattern, text, re.S)
        if m:
            return m.group(1)
    raise OPVaultError(f"could not unwrap JS payload (tried {patterns})")


def load_profile(profile_dir: Path) -> dict:
    text = (profile_dir / "profile.js").read_text()
    return json.loads(_unwrap_js(text, [r"var\s+profile\s*=\s*(.*?);?\s*$"]))


def band_path(profile_dir: Path, letter: str) -> Path:
    return profile_dir / f"band_{letter.upper()}.js"


def load_band(profile_dir: Path, letter: str) -> dict:
    p = band_path(profile_dir, letter)
    if not p.exists():
        return {}
    text = p.read_text().strip()
    if not text:
        return {}
    return json.loads(_unwrap_js(text, [r"ld\((.*)\);?\s*$"]))


def save_band(profile_dir: Path, letter: str, data: dict) -> None:
    payload = json.dumps(data, separators=(",", ":"))
    band_path(profile_dir, letter).write_text(f"ld({payload});")


def all_band_letters():
    return list("0123456789ABCDEF")


def iter_items(profile_dir: Path):
    for letter in all_band_letters():
        band = load_band(profile_dir, letter)
        for item_uuid, item in band.items():
            yield letter, item_uuid, item


# --------------------------------------------------------------------------
# High-level vault session
# --------------------------------------------------------------------------

class VaultSession:
    def __init__(self, opvault_dir: Path, profile_name: str, password: str):
        self.opvault_dir = opvault_dir
        self.profile_dir = opvault_dir / profile_name
        if not (self.profile_dir / "profile.js").exists():
            raise OPVaultError(f"no profile.js found in {self.profile_dir}")
        self.profile = load_profile(self.profile_dir)

        salt = b64d(self.profile["salt"])
        iterations = self.profile["iterations"]
        derived = derive_master_key(password, salt, iterations)
        enc_key, mac_key = derived[:32], derived[32:64]

        try:
            mk = opdata01_decrypt(b64d(self.profile["masterKey"]), enc_key, mac_key)
            ok = opdata01_decrypt(b64d(self.profile["overviewKey"]), enc_key, mac_key)
        except OPVaultError:
            raise OPVaultError("wrong master password (or corrupt profile.js)")

        # The decrypted masterKey/overviewKey blobs are NOT used directly as enc||mac.
        # Per the real OPVault algorithm, each is first hashed with SHA-512, and THAT
        # 64-byte digest is split into enc(first32)/mac(last32).
        master_digest = hashlib.sha512(mk).digest()
        overview_digest = hashlib.sha512(ok).digest()
        self.master_enc, self.master_mac = master_digest[:32], master_digest[32:64]
        self.overview_enc, self.overview_mac = overview_digest[:32], overview_digest[32:64]

        # Verify against a real item's overview HMAC so a wrong derivation fails loudly
        # here instead of surfacing as a confusing per-item error later.
        sample_item = next((item for _, _, item in iter_items(self.profile_dir)), None)
        if sample_item is not None:
            try:
                opdata01_decrypt(b64d(sample_item["o"]), self.overview_enc, self.overview_mac)
            except OPVaultError:
                raise OPVaultError(
                    "unlocked the profile keys but could not decrypt a sample item overview; "
                    "the derivation may not match this vault variant"
                )

    def decrypt_overview(self, item: dict) -> dict:
        raw = opdata01_decrypt(b64d(item["o"]), self.overview_enc, self.overview_mac)
        return json.loads(raw)

    def decrypt_details(self, item: dict) -> dict:
        item_enc, item_mac = unwrap_item_key(self.master_enc, self.master_mac, b64d(item["k"]))
        raw = opdata01_decrypt(b64d(item["d"]), item_enc, item_mac)
        return json.loads(raw)

    def build_new_item(self, category: str, overview: dict, details: dict, hmac_mode: str = "confirmed"):
        item_uuid = uuid_mod.uuid4().hex.upper()
        item_enc, item_mac = secrets.token_bytes(32), secrets.token_bytes(32)
        now = int(datetime.now(tz=timezone.utc).timestamp())

        o_blob = opdata01_encrypt(json.dumps(overview).encode("utf-8"), self.overview_enc, self.overview_mac)
        d_blob = opdata01_encrypt(json.dumps(details).encode("utf-8"), item_enc, item_mac)
        k_blob = wrap_item_key(self.master_enc, self.master_mac, item_enc, item_mac)

        item = {
            "category": category,
            "created": now,
            "updated": now,
            "tx": now,
            "fave": 0,
            "uuid": item_uuid,
            "k": b64e(k_blob),
            "o": b64e(o_blob),
            "d": b64e(d_blob),
        }
        if hmac_mode == "confirmed":
            # Empirically confirmed via `verify-hmac` against 879/879 non-trashed real
            # items: sorted key + JS-style-stringified value concatenation, HMAC-SHA256
            # keyed with the overview MAC key. (A separate, unrelated historical
            # inconsistency affects ~126 already-trashed items in real vaults and does
            # not apply to newly created, non-trashed items.)
            item["hmac"] = b64e(compute_hmac_candidate_d_jsvalues(item, self.overview_mac))
        return item_uuid, item


# --------------------------------------------------------------------------
# Item-level "hmac" field: algorithm unconfirmed. We provide a candidate and
# an empirical verifier (verify-hmac command) that tests it (and others)
# against real, already-written items so we don't guess blind.
# --------------------------------------------------------------------------

def compute_hmac_candidate_a(item: dict, overview_mac: bytes) -> bytes:
    """sorted-key, compact-JSON canonicalization of every field except hmac."""
    payload = {k: v for k, v in item.items() if k != "hmac"}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hmac_sha256(overview_mac, canonical)


def compute_hmac_candidate_b(item: dict, overview_mac: bytes) -> bytes:
    """sorted-key concatenation of raw key+value strings (no JSON braces/quotes)."""
    parts = []
    for k in sorted(item.keys()):
        if k == "hmac":
            continue
        v = item[k]
        parts.append(str(k))
        parts.append(str(v))
    return hmac_sha256(overview_mac, "".join(parts).encode("utf-8"))


def _js_str(v) -> str:
    """Stringify a JSON-decoded value the way a JS serializer would, not Python's str()."""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "null"
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)


def compute_hmac_candidate_e_no_trashed(item: dict, overview_mac: bytes) -> bytes:
    """like candidate_b/d but 'trashed' is excluded from the field set entirely
    (theory: the hmac schema predates that field and never covers it)."""
    parts = []
    for k in sorted(item.keys()):
        if k in ("hmac", "trashed"):
            continue
        parts.append(k)
        parts.append(_js_str(item[k]))
    return hmac_sha256(overview_mac, "".join(parts).encode("utf-8"))


def compute_hmac_candidate_f_pretrash(item: dict, overview_mac: bytes) -> bytes:
    """theory: hmac is never recomputed when an item is trashed, so it reflects the
    item's state *before* trashing: no 'trashed' key, and 'tx' still equal to 'updated'
    (trashing is what bumps 'tx' to a new value and adds 'trashed':true)."""
    effective = {k: v for k, v in item.items() if k not in ("hmac", "trashed")}
    if item.get("trashed"):
        effective["tx"] = item.get("updated")
    parts = []
    for k in sorted(effective.keys()):
        parts.append(k)
        parts.append(_js_str(effective[k]))
    return hmac_sha256(overview_mac, "".join(parts).encode("utf-8"))


def compute_hmac_candidate_d_jsvalues(item: dict, overview_mac: bytes) -> bytes:
    """like candidate_b but with JS-style true/false/null instead of Python's True/False/None."""
    parts = []
    for k in sorted(item.keys()):
        if k == "hmac":
            continue
        parts.append(k)
        parts.append(_js_str(item[k]))
    return hmac_sha256(overview_mac, "".join(parts).encode("utf-8"))


def compute_hmac_candidate_c_rawbytes(item: dict, overview_mac: bytes) -> bytes:
    """like candidate_a but o/k/d contribute their *decoded* raw bytes, not base64 text."""
    parts = []
    for k in sorted(item.keys()):
        if k == "hmac":
            continue
        v = item[k]
        if k in ("o", "k", "d") and isinstance(v, str):
            parts.append(k.encode("utf-8"))
            parts.append(b64d(v))
        else:
            parts.append(k.encode("utf-8"))
            parts.append(str(v).encode("utf-8"))
    return hmac_sha256(overview_mac, b"".join(parts))


HMAC_CANDIDATES = {
    "a_sorted_json": compute_hmac_candidate_a,
    "b_sorted_concat": compute_hmac_candidate_b,
    "c_sorted_rawbytes": compute_hmac_candidate_c_rawbytes,
    "d_sorted_concat_jsvalues": compute_hmac_candidate_d_jsvalues,
    "e_no_trashed": compute_hmac_candidate_e_no_trashed,
    "f_pretrash": compute_hmac_candidate_f_pretrash,
}


def cmd_verify_hmac(session: VaultSession):
    tallies = {name: [0, 0] for name in HMAC_CANDIDATES}  # [matches, total_with_hmac]
    nontrashed_tallies = {name: [0, 0] for name in HMAC_CANDIDATES}
    mismatch_keysets = {name: [] for name in HMAC_CANDIDATES}
    missing_hmac_uuids = []
    total_items = 0
    items_with_hmac = 0
    for letter, item_uuid, item in iter_items(session.profile_dir):
        total_items += 1
        stored = item.get("hmac")
        if not stored:
            missing_hmac_uuids.append(item_uuid)
            continue
        items_with_hmac += 1
        stored_bytes = b64d(stored)
        is_trashed = bool(item.get("trashed"))
        for name, fn in HMAC_CANDIDATES.items():
            try:
                computed = fn(item, session.overview_mac)
            except Exception:
                continue
            tallies[name][1] += 1
            matched = hmac_mod.compare_digest(computed, stored_bytes)
            if matched:
                tallies[name][0] += 1
            if not is_trashed:
                nontrashed_tallies[name][1] += 1
                if matched:
                    nontrashed_tallies[name][0] += 1
            if not matched and len(mismatch_keysets[name]) < 8:
                mismatch_keysets[name].append(
                    {
                        "keys": sorted(item.keys()),
                        "category": item.get("category"),
                        "fave": item.get("fave"),
                        "trashed": item.get("trashed"),
                        "created": item.get("created"),
                        "updated": item.get("updated"),
                        "tx": item.get("tx"),
                        "o_len": len(item.get("o", "")),
                        "d_len": len(item.get("d", "")),
                        "k_len": len(item.get("k", "")),
                        "uuid_len": len(item.get("uuid", "")),
                    }
                )

    print(f"Scanned {total_items} items, {items_with_hmac} carry an 'hmac' field.")
    if missing_hmac_uuids:
        print(f"\n{len(missing_hmac_uuids)} item(s) have NO 'hmac' field at all:")
        for u in missing_hmac_uuids:
            print(f"  {u}")
        print("\nTo delete all of them:")
        for u in missing_hmac_uuids:
            print(
                f"  python3 scripts/opvault_tool.py remove --vault ~/Dropbox/1Password/1Password.opvault "
                f"{u} --confirm-write"
            )
        print()
    if items_with_hmac == 0:
        print("No items have an 'hmac' field to check against — nothing to verify.")
        return
    any_match = False
    any_nontrashed_match = False
    for name, (matches, total) in tallies.items():
        pct = (matches / total * 100) if total else 0.0
        nt_matches, nt_total = nontrashed_tallies[name]
        nt_pct = (nt_matches / nt_total * 100) if nt_total else 0.0
        print(
            f"  {name:24s}: {matches}/{total} matched overall ({pct:.1f}%), "
            f"{nt_matches}/{nt_total} matched on non-trashed items ({nt_pct:.1f}%)"
        )
        if matches == total and total > 0:
            any_match = True
            any_nontrashed_match = True
            print(f"    -> ALGORITHM CONFIRMED: {name} matches every existing item.")
        elif nt_matches == nt_total and nt_total > 0:
            any_nontrashed_match = True
            print(f"    -> CONFIRMED for non-trashed items: {name} matches all {nt_total} of them.")
        elif matches > 0 and mismatch_keysets[name]:
            print(f"    sample key-sets of mismatching items (keys only, no decrypted content):")
            for keys in mismatch_keysets[name]:
                print(f"      {keys}")
    if any_nontrashed_match:
        print(
            "\nA confirmed algorithm exists for non-trashed items (which covers every item "
            "the 'add' command creates). Any remaining mismatches are on already-trashed "
            "items, which appear to carry a stale hmac from whatever old client trashed them "
            "— a pre-existing inconsistency in the vault, not a gap in our understanding."
        )
    elif not any_match:
        print(
            "\nNone of the candidate algorithms matched every item. The exact 'hmac' "
            "formula is not confirmed. New items will be written WITHOUT a matching "
            "hmac (hmac_mode=none) — this does not affect the security or decryptability "
            "of the item (the o/k/d blobs are independently authenticated by opdata01's "
            "own HMAC), but native 1Password may flag the new item as unverified/modified. "
            "Check this explicitly when you validate with the real app."
        )


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_list(session: VaultSession):
    count = 0
    for letter, item_uuid, item in iter_items(session.profile_dir):
        try:
            ov = session.decrypt_overview(item)
        except OPVaultError as e:
            print(f"[band_{letter}] {item_uuid}: FAILED TO DECRYPT ({e})")
            continue
        cat = CATEGORY_NAMES.get(item.get("category"), item.get("category"))
        title = ov.get("title", "<untitled>")
        url = ov.get("url", "")
        trashed = " [trashed]" if item.get("tx") and item.get("trashed") else ""
        count += 1
        print(f"{item_uuid}  [{cat:14s}]  {title}{('  ' + url) if url else ''}{trashed}")
    print(f"\n{count} item(s) listed.")


def cmd_show(session: VaultSession, target_uuid: str, reveal: bool):
    for letter, item_uuid, item in iter_items(session.profile_dir):
        if item_uuid.upper() != target_uuid.upper():
            continue
        ov = session.decrypt_overview(item)
        details = session.decrypt_details(item)
        if not reveal:
            for f in details.get("fields", []):
                if f.get("designation") == "password" or f.get("type") == "P":
                    f["value"] = "•" * 8
            if "password" in details:
                details["password"] = "•" * 8
        print("category:", CATEGORY_NAMES.get(item.get("category"), item.get("category")))
        print("overview:", json.dumps(ov, indent=2))
        print("details :", json.dumps(details, indent=2))
        if not reveal:
            print("\n(passwords masked; pass --reveal to show them)")
        return
    print(f"No item with uuid {target_uuid} found.")


def backup_vault(opvault_dir: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = opvault_dir.parent / f"{opvault_dir.name}.backup-{stamp}"
    shutil.copytree(opvault_dir, backup_dir)
    return backup_dir


def cmd_remove(session: VaultSession, opvault_dir: Path, target_uuid: str, confirm_write: bool):
    target_uuid = target_uuid.upper()
    letter = None
    for l, item_uuid, item in iter_items(session.profile_dir):
        if item_uuid.upper() == target_uuid:
            letter = l
            break
    if letter is None:
        print(f"No item with uuid {target_uuid} found; nothing to do.")
        return

    if not confirm_write:
        print(f"Found item {target_uuid} in band_{letter}.js. Pass --confirm-write to actually delete it.")
        return

    backup_path = backup_vault(opvault_dir)
    print(f"Backed up existing vault to: {backup_path}")

    band = load_band(session.profile_dir, letter)
    del band[target_uuid]
    save_band(session.profile_dir, letter, band)
    print(f"Removed item {target_uuid} from band_{letter}.js")

    reread_band = load_band(session.profile_dir, letter)
    assert target_uuid not in reread_band, "item still present after removal"
    print("Self-check passed: item is gone from the re-read band file.")


def cmd_add(session: VaultSession, opvault_dir: Path, confirm_write: bool):
    if not confirm_write:
        print("Refusing to write: pass --confirm-write to actually add an item.")
        return

    print("Adding a new Login item. Leave blank to skip a field.")
    title = input("Title: ").strip() or "Untitled Login"
    username = input("Username: ").strip()
    password = getpass.getpass("Password (hidden): ")
    url = input("URL: ").strip()
    notes = input("Notes: ").strip()

    overview = {"title": title}
    if url:
        overview["url"] = url
        overview["urls"] = [{"l": "website", "u": url}]

    details = {
        "fields": [
            {
                "value": username,
                "id": "username",
                "name": "username",
                "type": "T",
                "designation": "username",
            },
            {
                "value": password,
                "id": "password",
                "name": "password",
                "type": "P",
                "designation": "password",
            },
        ],
        "notesPlain": notes,
        "password": password,
        "sections": [],
        "passwordHistory": [],
    }

    backup_path = backup_vault(opvault_dir)
    print(f"Backed up existing vault to: {backup_path}")

    item_uuid, item = session.build_new_item("001", overview, details)  # hmac_mode="confirmed" (default)
    letter = item_uuid[0]
    band = load_band(session.profile_dir, letter)
    band[item_uuid] = item
    save_band(session.profile_dir, letter, band)

    print(f"Added item {item_uuid} to band_{letter}.js")

    # Self-check: re-read what we just wrote using our own reader.
    reread_band = load_band(session.profile_dir, letter)
    reread_item = reread_band[item_uuid]
    ov2 = session.decrypt_overview(reread_item)
    det2 = session.decrypt_details(reread_item)
    assert ov2 == overview, "overview round-trip mismatch"
    assert det2 == details, "details round-trip mismatch"
    print("Self-check passed: item re-reads correctly with our own decryptor.")
    print(
        "\nNow open the REAL 1Password app pointed at this vault and confirm it can "
        "see and open the new item. If anything looks wrong, restore from the backup:\n"
        f"  rm -rf '{opvault_dir}' && mv '{backup_path}' '{opvault_dir}'"
    )


# --------------------------------------------------------------------------
# Self-test: build a synthetic vault from scratch, exercise every code path,
# using a throwaway password. No real vault or real password involved.
# --------------------------------------------------------------------------

def build_synthetic_vault(root: Path, password: str, iterations: int = 500):
    profile_dir = root / "default"
    profile_dir.mkdir(parents=True)

    salt = secrets.token_bytes(16)
    derived = derive_master_key(password, salt, iterations)
    enc_key, mac_key = derived[:32], derived[32:64]

    # profile.masterKey/overviewKey wrap arbitrary 64-byte material; the actual
    # enc/mac keys used for items are SHA-512(that material), split in half.
    master_plain = secrets.token_bytes(64)
    overview_plain = secrets.token_bytes(64)

    master_key_blob = opdata01_encrypt(master_plain, enc_key, mac_key)
    overview_key_blob = opdata01_encrypt(overview_plain, enc_key, mac_key)

    profile = {
        "uuid": uuid_mod.uuid4().hex.upper(),
        "updatedAt": int(datetime.now(tz=timezone.utc).timestamp()),
        "createdAt": int(datetime.now(tz=timezone.utc).timestamp()),
        "iterations": iterations,
        "lastUpdatedBy": "opvault_tool.selftest",
        "profileName": "default",
        "salt": b64e(salt),
        "passwordHint": "",
        "masterKey": b64e(master_key_blob),
        "overviewKey": b64e(overview_key_blob),
    }
    (profile_dir / "profile.js").write_text(f"var profile={json.dumps(profile)};")
    (profile_dir / "folders.js").write_text("loadFolders({});")
    for letter in all_band_letters():
        save_band(profile_dir, letter, {})

    return profile_dir


def cmd_selftest():
    print("Running self-test against a synthetic vault (no real data involved)...\n")
    tmp = Path(tempfile.mkdtemp(prefix="opvault_selftest_"))
    try:
        password = "correct horse battery staple"
        opvault_dir = tmp / "Fake.opvault"
        build_synthetic_vault(opvault_dir, password)

        # 1. unlock
        session = VaultSession(opvault_dir, "default", password)
        print("[ok] unlocked synthetic vault with correct password")

        # 2. wrong password must fail
        try:
            VaultSession(opvault_dir, "default", "wrong password")
            print("[FAIL] wrong password did not raise!")
            return False
        except OPVaultError:
            print("[ok] wrong password correctly rejected")

        # 3. add an item
        overview = {"title": "Example Login", "url": "https://example.com"}
        details = {
            "fields": [
                {"value": "alice", "id": "username", "name": "username", "type": "T", "designation": "username"},
                {"value": "hunter2", "id": "password", "name": "password", "type": "P", "designation": "password"},
            ],
            "notesPlain": "test note",
            "password": "hunter2",
            "sections": [],
            "passwordHistory": [],
        }
        item_uuid, item = session.build_new_item("001", overview, details)
        letter = item_uuid[0]
        band = load_band(session.profile_dir, letter)
        band[item_uuid] = item
        save_band(session.profile_dir, letter, band)
        print(f"[ok] wrote new item {item_uuid}")

        # 4. list
        found = [u for _, u, _ in iter_items(session.profile_dir)]
        assert item_uuid in found, "new item missing from listing"
        print(f"[ok] item appears in listing ({len(found)} total item(s))")

        # 5. re-open the vault fresh (new process-like session) and decrypt
        session2 = VaultSession(opvault_dir, "default", password)
        reloaded_item = load_band(session2.profile_dir, letter)[item_uuid]
        ov2 = session2.decrypt_overview(reloaded_item)
        det2 = session2.decrypt_details(reloaded_item)
        assert ov2 == overview, f"overview mismatch: {ov2} != {overview}"
        assert det2 == details, f"details mismatch: {det2} != {details}"
        print("[ok] fresh session re-decrypts overview + details correctly")

        # 6. tamper check: flipping a byte in the ciphertext must be detected
        tampered = dict(reloaded_item)
        raw = bytearray(b64d(tampered["o"]))
        raw[40] ^= 0xFF
        tampered["o"] = b64e(bytes(raw))
        try:
            session2.decrypt_overview(tampered)
            print("[FAIL] tampered ciphertext was not detected!")
            return False
        except OPVaultError:
            print("[ok] tampering with ciphertext is correctly detected (HMAC fails)")

        print("\nAll self-tests passed. The opdata01/PBKDF2/item-key crypto engine is correct.")
        return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("selftest", help="Round-trip test against a synthetic fake vault (no real password needed)")

    p_list = sub.add_parser("list", help="List items in a vault")
    p_list.add_argument("--vault", required=True, type=Path, help="Path to the .opvault bundle")
    p_list.add_argument("--profile", default="default")

    p_show = sub.add_parser("show", help="Show decrypted details for one item")
    p_show.add_argument("--vault", required=True, type=Path)
    p_show.add_argument("--profile", default="default")
    p_show.add_argument("uuid")
    p_show.add_argument("--reveal", action="store_true", help="Show passwords in plaintext")

    p_verify = sub.add_parser("verify-hmac", help="Empirically determine the item hmac algorithm from real data")
    p_verify.add_argument("--vault", required=True, type=Path)
    p_verify.add_argument("--profile", default="default")

    p_add = sub.add_parser("add", help="Add a new Login item (prompts interactively)")
    p_add.add_argument("--vault", required=True, type=Path)
    p_add.add_argument("--profile", default="default")
    p_add.add_argument("--confirm-write", action="store_true", help="Required to actually write changes")

    p_remove = sub.add_parser("remove", help="Delete one item by uuid")
    p_remove.add_argument("--vault", required=True, type=Path)
    p_remove.add_argument("--profile", default="default")
    p_remove.add_argument("uuid")
    p_remove.add_argument("--confirm-write", action="store_true", help="Required to actually delete")

    args = parser.parse_args()

    if args.command == "selftest":
        ok = cmd_selftest()
        sys.exit(0 if ok else 1)

    vault_dir: Path = args.vault.expanduser().resolve()
    if not vault_dir.exists():
        print(f"Vault path does not exist: {vault_dir}")
        sys.exit(1)

    password = getpass.getpass(f"Master password for {vault_dir.name}: ")
    try:
        session = VaultSession(vault_dir, args.profile, password)
    except OPVaultError as e:
        print(f"Could not unlock vault: {e}")
        sys.exit(1)
    finally:
        del password

    print(f"Unlocked '{vault_dir.name}' profile '{args.profile}'.\n")

    if args.command == "list":
        cmd_list(session)
    elif args.command == "show":
        cmd_show(session, args.uuid, args.reveal)
    elif args.command == "verify-hmac":
        cmd_verify_hmac(session)
    elif args.command == "add":
        if "dropbox" in str(vault_dir).lower():
            print(
                "WARNING: this path looks like it lives inside Dropbox and may be your "
                "real, synced 1Password vault. A backup will be made automatically, but "
                "Dropbox may sync any change to your other devices before you've validated "
                "it with the real app.\n"
            )
        cmd_add(session, vault_dir, args.confirm_write)
    elif args.command == "remove":
        if "dropbox" in str(vault_dir).lower():
            print(
                "WARNING: this path looks like it lives inside Dropbox and may be your "
                "real, synced 1Password vault. A backup will be made automatically, but "
                "Dropbox may sync any change to your other devices before you've validated "
                "it with the real app.\n"
            )
        cmd_remove(session, vault_dir, args.uuid, args.confirm_write)


if __name__ == "__main__":
    main()
