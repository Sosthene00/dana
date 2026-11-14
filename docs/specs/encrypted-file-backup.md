# Dana Wallet — Encrypted File Backup (Format v1)

- **Status:** Ratified v1.0 (2026-11-14, founder sign-off). Derived from the locked decision record D1–D12 (grill, 2026-11-12/13).
- **Target codebase:** `cygnet3/dana` at commit `6ee42226ed19aacba44767c5e4d7009b2b611ed9` (tip of `upstream/bip392`).
- **Normative language:** The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in RFC 2119.
- **Scope:** v1 only, except §8 (Escrow v2), which is a forward-compatibility summary. Nothing in this document commits v1 to escrow functionality.

---

## 1. Overview

Dana wallets need a single-file, encrypted, portable backup that captures the complete recoverable state of a silent-payments wallet. One file, one password, one restore. The container is Dana-private; the inner payload is a **spec-valid BIP-139 export** so that payload compliance can be tested independently of the container (D2, D3).

Goals, in priority order:

1. **Single artifact.** ONE encrypted file contains the BIP-139 payload plus the Dana secrets block (D4). No metadata-only export in v1.
2. **Compliance.** The decrypted BIP-139 section MUST validate as a BIP-139 export on its own (D2, D3). Mainnet exports MUST NOT contain spend keys or mnemonics *inside the BIP-139 section*; the spend key lives only in the Dana secrets block, which never exists outside encryption.
3. **Offline-attack resistance.** The password is the only human secret protecting the file; the KDF parameters are sized so that an offline brute-force rig is the attacker's only viable strategy — and it fails on sane passwords (D8, §5).
4. **Exact-state restore.** Restoring the file reproduces the wallet state; no seed phrase is required at restore time and no rescan is needed to recover scan state (BIP-139 carries it; D9). See the TODO in §6.3 on the exact restore promise.
5. **v2 headroom.** The v1 header reserves the fields the escrow design (D6, D7) needs, so v2 files never diverge structurally from v1 files (D12).

Non-goals for v1: escrow service operation, Blindbit URL / dust-limit sync settings, contacts and settings beyond an optional passthrough section, any plaintext export mode.

---

## 2. Threat model

**Primary adversary: offline file theft.** The attacker obtains the backup file (stolen laptop, shared folder, exfiltrated cloud sync, seized storage) and has unlimited offline time. The file MUST NOT reveal keys, addresses, labels, transaction graph, or contacts without the password.

**Cloud sync exposure.** Users WILL store this file in cloud drives. Treat every copy of the file as public from the moment it is written. The design assumes zero confidentiality from the storage provider.

**What the attacker knows:** the file, the format spec (this document), the BIP-139 spec, and Dana's source code. Security rests on the password and the KDF parameters, not on obscurity.

**Future-privacy note (from the D5 ruling):** because the encrypted payload includes the private scan key, a file that falls to a password attack leaks the *past* transaction graph. It does not enable computation of future output tweaks without the spend key, but metadata (past graph, labels, contacts) must not be obtainable by a password-only attack — this is why the layered Variant B ("public metadata at password layer") was declined: metadata MUST NOT fall to a password-only attack either.

**Three recovery scenarios** the format must serve:

1. **File + password (primary).** User has the file and remembers the password → full restore from file alone. No seed required.
2. **Seed only (bad case).** User lost the file (or password) but has the seed phrase → existing seed-restore + rescan path. This is the pre-existing fallback and is explicitly accepted as the degraded path (D4). It restores funds; it does not restore labels/contacts.
3. **Escrow-dead (v2, out of scope for v1 mechanics).** All local material lost except the password; recovery via the escrow donation-secret mechanism (§8). v1 only guarantees the header reservation makes this possible later (D12).

---

## 3. File format v1

### 3.1 Top-level structure

The file is: **cleartext authenticated header || ciphertext || AEAD tag**.

- One-shot AEAD encryption. The entire header — every byte, magic included — is supplied as **AAD** to the AEAD. Any header modification (version downgrade, Argon2 parameter tampering, escrow-entry injection) fails authentication. The header is not separately signed or MAC'd.
- The header is variable-length because of reserved escrow space; it is self-delimiting via `header_len`.
- All multi-byte integers are **little-endian**.
- All zero-padding fields MUST be zero on write; readers MUST treat nonzero reserved bytes as a parse error (they are AAD anyway, so tampering fails first).

### 3.2 Magic bytes

Magic is the 8 ASCII bytes `"DANABKP1"`. Rationale: identifies the product and the format epoch in one token; the trailing digit pairs visually with `format_version`; "BKP" disambiguates from Dana's network-facing file types; 8 bytes keeps the header 16-byte aligned at the Argon2 field boundary. Files MUST begin with these exact bytes; readers MUST reject anything else before parsing further.

### 3.3 Header layout

```text
Header (cleartext, entire region is AEAD AAD):

Offset      Size   Field
0x00        8      magic          = "DANABKP1" (ASCII)
0x08        1      format_version = 0x01
0x09        1      cipher_id      (see §3.4)
0x0A        2      header_len     LE u16 — total header size in bytes
0x0C        4      reserved       (zero)
0x10        4      argon2_m_kib   LE u32 — Argon2id memory, KiB (= 65536)
0x14        4      argon2_t       LE u32 — Argon2id passes (= 3)
0x18        4      argon2_p       LE u32 — Argon2id lanes  (= 1)
0x1C        16     argon2_salt    uniformly random, fresh per file
                                  NOTE: argon2_m_kib / argon2_t / argon2_p are
                                  serialized per file and MAY deviate from the
                                  defaults ONLY via the device-class fallback
                                  (§6.3). Decrypt-side MUST honor the header
                                  values as written — never hardcode defaults.
0x2C        1      nonce_len      number of nonce bytes actually used
0x2D        24     aead_nonce     random; only first nonce_len bytes are
                                  consumed, remainder zero-padded
0x45        4      escrow_entry_count LE u32 — v1 writes 0
0x49        32*N   escrow_pair_i  i = 0..N-1, each pair:
                     txid_i   32 bytes  (donation txid, byte order as
                                        displayed by `txid` serialization)
                     H(s_i)   32 bytes  (SHA-256 of the donation shared
                                        secret s_i — never s_i itself)
0x49+32*N   8      payload_len    LE u64 — ciphertext length in bytes

header_len = 0x51 + 32 * escrow_entry_count
```

- `payload_len` counts ciphertext bytes only; the 16-byte AEAD tag immediately follows the ciphertext and is not included in `payload_len`.
- Readers: read the first 16 bytes, read `header_len` bytes total, use those `header_len` bytes as AAD, then decrypt `payload_len` bytes and verify the trailing tag.
- v1 writers MUST write `escrow_entry_count = 0` and MUST NOT write escrow pairs. The field and layout exist so a v2 writer can add pairs without changing anything else (D12). A v1 reader encountering `escrow_entry_count > 0` MUST fail restore with a "file written by a newer version" error — v1 cannot have produced such a file, and a v2 file may rely on key material v1 does not understand.

### 3.4 Cipher

**DECIDED (founder ruling, 2026-11-13): XChaCha20-Poly1305** (RustCrypto `chacha20poly1305` crate, `cipher_id = 0x01`). This is the algorithm and the implementation for v1 — the choice covers both, so implementations MUST use the RustCrypto crates (`chacha20poly1305`, `argon2`, `hkdf`, all pure Rust) and MUST NOT substitute a different provider without a spec revision.

- 192-bit random nonce: collision probability is negligible for any conceivable generation volume; no nonce-management discipline needed for one-shot file encryption.
- Constant-time software implementation; the RustCrypto AEAD crates (aes-gcm and chacha20poly1305, plus the underlying chacha20/poly1305) received an NCC Group implementation review (MobileCoin, published 2020) with **no vulnerabilities found** and constant-time techniques confirmed. The `chacha20` stream core is already in Dana's dependency tree (via `rand`); the new surface is Poly1305 and the AEAD framing only.
- 24-byte nonce fits the fixed 24-byte `aead_nonce` field exactly.

**AES-256-GCM remains defined** (`cipher_id = 0x02`, AES-256-GCM with a 12-byte nonce placed in the same field, `nonce_len = 12`) as an optional reader-side capability only: readers SHOULD support both IDs so v1-compliant files encrypted with either algorithm remain readable, but v1 writers produce XChaCha20-Poly1305 exclusively.

Implementation hygiene (REQUIRED before merge): run `cargo audit` and resolve or explicitly accept every finding on the newly added crypto crates; the RustCrypto `argon2` crate has no dedicated third-party audit (the AEAD half does) — accepted, since its role is password stretching, not confidentiality (§2).

AEAD tag: Poly1305 tag (XChaCha) or GHASH tag (AES-GCM), 16 bytes either way, appended after the ciphertext. Decryption failure is terminal — no partial output is ever exposed (§9, vectors 4–5).

---

## 4. Encryption key derivation (v1)

```text
Step 1:  ikm = Argon2id(
             password   = UTF-8 encoded password/passphrase (no trimming),
             salt       = argon2_salt            (from header),
             m          = argon2_m_kib KiB       (from header; v1 = 65536),
             t          = argon2_t               (from header; v1 = 3),
             p          = argon2_p               (from header; v1 = 1),
             output_len = 32 bytes)

Step 2:  aead_key = HKDF-SHA256(
             ikm  = ikm,
             salt = magic || format_version          ("DANABKP1" || 0x01),
             info = "Dana backup v1 AEAD key",
             L    = 32 bytes)
```

- Parameters are read **from the header**, not hardcoded, so the header is the single source of truth; the AAD binding guarantees they were the ones used at encryption time.
- The HKDF step separates key use from key material: the Argon2id output could later be combined with escrow-derived material without redefining what the AEAD consumes (§4.1).
- v1 files use a fixed-purpose string; a v2 key schedule MUST use a different `info` string if its input domain differs, so v1 keys and v2 keys can never coincide.

### 4.1 v2 combiner slot (reserved, not implemented)

The escrow design (D6, D7) replaces Step 1's input: the v2 key schedule derives the AEAD key from **both** the password and a donation shared secret `s_i` via a combiner `f(s_i, password)`, then runs the same HKDF step. Properties the combiner must have, so the v1 header reservation can be trusted to suffice:

- Both factors REQUIRED: knowledge of `s_i` alone, or password alone, yields nothing (D7 constraint; this is what defeated Variant C, D5).
- One-way in the stronger factor: an attacker who recovers the AEAD key via password compromise learns nothing about `s_i`.

v1 makes no combiner claim beyond: the header already carries `(txid_i, H(s_i))` space, the KDF params are header-driven, and the HKDF purpose string is versioned. Files written by v1 are structurally valid inputs to a v2 reader that understands the reserved fields.

#### 4.1.1 Combiner definition (v2, normative for the v2 writer)

**DECIDED (founder ruling, 2026-11-13):** the combiner is a **cascade, not a merge**. Argon2id is run twice, the password pass nested inside the escrow pass:

```text
k_pass  = Argon2id(password, salt_1, m=64MiB, t=3, p=1)   // header params, v1 profile
key_material = Argon2id(s_i || H(k_pass), salt_2, m=64MiB, t=3, p=1)
```

- `salt_1` and `salt_2` are two independent 16-byte salts in the v2 header extension. `salt_1` occupies the same position as the v1 `argon2_salt` field; `salt_2` is new.
- `H` is SHA-256. `H(k_pass)` (never raw `k_pass`) is fed into the second pass so that a compromise of the second pass's intermediate state does not expose the password-derived key directly.
- Ordering rationale: putting the password INSIDE the escrow pass means an attacker without `s_i` must brute-force a memory-hard function whose input they cannot even complete — password-only and secret-only attacks both fall to the memory-hard wall, satisfying both §4.1 properties. (The XOR construction was rejected: XOR of two KDF outputs degrades if either factor is weak in a structured way, and Argon2id's input is long enough to host the concatenation natively, so no benefit justified the extra construction.)
- The concatenated input `s_i || H(k_pass)` is 64 bytes — well within Argon2id's input limits; no pre-hashing needed.
- The result flows into the SAME HKDF-Extract/Expand step as v1 (§4) with `info = "Dana backup v2 AEAD key"` — the versioned purpose string guarantees v1 keys and v2 keys can never coincide.
- Header form: v2 files are v1 files with `format_version = 0x02`, `escrow_entry_count ≥ 1`, and a `salt_2` field appended inside the escrow section of the header. A v1 reader MUST reject v2 files (see §3.3 v1-reader rule); a v2 reader MAY read v1 files by treating `key_material = k_pass` (i.e. skipping the outer pass).

---

## 5. Inner payload layout

The decrypted plaintext is a sequence of length-prefixed sections:

```text
Plaintext (after successful AEAD decrypt+verify):

Per section:
  0..4    4   section_type  LE u32
  4..8    4   section_len   LE u32 — byte length of section_body
  8..     n   section_body

Sections in v1 (order fixed, presence per table below):

  type         section                presence   body format
  0x00000001   BIP-139 payload        REQUIRED   UTF-8 JSON, BIP-139 export
  0x00000002   Dana secrets block     REQUIRED   UTF-8 JSON (see 5.2)
  0x00000003   Companion fields       OPTIONAL   UTF-8 JSON (see 5.3)

Readers MUST process sections in order and MUST ignore section types
they do not recognize (forward compatibility: a v2 file may append
sections a v1 reader can safely skip — but a v1 reader will still fail
on escrow-bound header material per §3.3).
```

### 5.1 BIP-139 payload section (0x00000001)

- The section body MUST be a **spec-valid BIP-139 export** (BIP-139, Draft, PR #2130): `bip392` account type, `bip352_labels`, per-coin `tweak`/`sp_label`, BIP-329 labels, extensible registry.
- Scan state lives here (the BIP-139 export's scan fields). There is deliberately **no** `lastScan` field anywhere in the container — file restore is exact-state because BIP-139 already carries scan state (D9).
- Mainnet constraint (D2): the BIP-139 section on mainnet MUST NOT contain spend keys or mnemonics. The private scan key MAY be present here per BIP-139's allowance.
- BIP-138 was evaluated and REJECTED as the container format because it excludes private material outright; the BIP-139 section's restraint is a compliance property, not a limitation, because the secrets block (5.2) carries what BIP-139 cannot.

### 5.2 Dana secrets block (0x00000002)

```text
{
  "descriptor": "<full encoded sp() spend descriptor>"
}
```

- Per D11, the spend key is stored as the **full encoded `sp()` descriptor**, not a raw scalar. This is the string produced by `WalletInfo::get_encoded_descriptor()` (`rust/src/api/wallet/info.rs`, the `SpKey::Spend` form: scan key + spend secret in one encoded key). Rationale: it plugs directly into the restore-by-pasted-descriptor onboarding path at 6ee4222, it carries key-type/tweak metadata, and it is self-describing for future key variants.
- The watch-only variants (`get_encoded_descriptor_watch_only()`, `get_two_key_descriptor_watch_only()`) and the two-key secret variant (`get_two_key_descriptor()`) exist in the API; v1 stores the single full descriptor above. The two-key form is noted as a possible extension but is NOT part of v1.
- The secrets block exists only inside the encrypted payload — it is never serialized to the BIP-139 section, to logs, or to any plaintext surface.

### 5.3 Companion fields section (0x00000003, optional)

- Carries contacts and settings deemed essential (D9). Written when the wallet has any; omitted otherwise.
- **Excluded from v1, deliberately:** PIN (NEVER enters the file under any circumstance), `lastScan` (BIP-139 owns scan state), Blindbit URL, dust limit (both deferred — see D9).
- Exact JSON schema for this section is deferred until the contacts/settings storage shape is settled; v1 implementations that have nothing to store simply omit the section.

---

## 6. Password policy (D8)

### 6.1 Rules for user-chosen passwords

Enforced deterministically at export time; no entropy meter, no scoring UI (rejected as unmeasurable theater in the ruling):

1. Length MUST be >= 16 characters (counted in Unicode scalar values, not bytes).
2. MUST contain at least one lowercase character.
3. MUST contain at least one digit.

The checks are plain boolean predicates over the entered string. No blocklist, no zxcvbn, no "strength" bar.

### 6.2 Generated passphrase option

The export UI MUST offer a generated option: a **6-word passphrase** from a diceware-style wordlist (~77 bits), separated by spaces. It satisfies §6.1 as written (lowercase words contain lowercase; the wordlist MUST include digits — e.g. digit-suffixed entries — so the digit rule passes without user surgery). A generated passphrase is displayed once, with the standard "store it safely" warning; the app MUST NOT persist it.

### 6.3 KDF and rationale

Password KDF: **Argon2id, m = 64 MiB, t = 3, p = 1** (D8), serialized in the header (§3.3).

Rationale, with the offline-attack numbers from the ruling: against an 8× RTX-5090 cracking rig, Argon2id at m=64 MiB t=3 yields roughly **96 guesses/second per rig**. A password with ~40 bits of effective unpredictability then costs on the order of **181 years** at that rate. The 16-character floor exists to keep non-dictionary passwords above that effective-entropy bar; the 6-word generated passphrase (~77 bits) sits far above it and is the recommended default for users without a password habit. This is also why password-only access to the file is the single point of failure for scenario 1 — and why §4.1's future two-factor combiner is structurally anticipated but not relied upon in v1.

Device-floor analysis and the encrypt-side fallback are in §6.3.1–§6.3.2; the remaining verification item is §10 (b).

#### 6.3.1 Published baselines for the 64 MiB choice

The default parameters are not arbitrary; they match published recommendations for exactly this situation (password protection of high-value material on memory-constrained devices):

- **RFC 9106** (Argon2 standard, §4 and §7.4) defines two recommended profiles: 2 GiB / t=1 for unconstrained environments, and **m = 64 MiB, t = 3** as the "SECOND RECOMMENDED option … suggested as a default setting for memory-constrained environments." Dana's default IS the RFC's constrained profile (Dana fixes p=1; lanes affect defender-side speed, not attacker cost, since cracking rigs parallelize lanes freely).
- **OWASP Password Storage Cheat Sheet** sets its *minimum* at m = 19 MiB, t = 2, p=1, explicitly as a floor with upward tuning expected.
- **Bitwarden** ships m = 64 MiB, t = 3, p = 4 as the default KDF on every platform, including old low-end Android devices, and documents no Android floor issue; the only platform where >64 MiB triggers OS warnings is iOS extensions (autofill) without biometric unlock — 64 MiB is already the proven-safe iOS ceiling.
- **Android floor (Google Build-for-Billions):** Android (Go edition) minimum RAM is 512 MB (Android 8.1–10), 1 GB (11–12), 2 GB (13+); guidance caps app steady-state PSS at 90 MB on Go devices. A one-shot, user-initiated, foreground 64 MiB Argon2id allocation (~150–250 ms on modern cores, ~1–2 s on weak ARM cores) is transient, not steady-state, and fits that budget.

Estimated bar: **m = 64 MiB clears every non-Go Android device (≥2 GB RAM) comfortably, and 1 GB Android 11+ Go devices acceptably; only 512 MB-era Android Go devices are marginal.**

#### 6.3.2 Device-class fallback (encrypt-side only)

Because the KDF parameters are serialized per file (§3.3), a floor device never forces a format change:

- At **encrypt** time, if `ActivityManager.isLowRamDevice()` is true AND the device cannot afford the default, the app MAY fall back to **m = 32 MiB, t = 4, p = 1** (constant ~time·memory product; same OWASP-floor-class resistance against GPU rigs given the §6.1 password rules), recording the actual values in the header.
- At **decrypt** time the implementation MUST use the header values as written. No device-class logic exists on the restore path.
- The fallback MUST be visible in the export UI ("reduced KDF settings for this device"), never silent — silently weakening defaults for all devices is forbidden; this mechanism weakens nothing for anyone but the device that cannot afford more.

---

## 7. Backup and restore flows

### 7.1 Backup (export)

1. User opens export in the wallet. The export is always encrypted — there is **no plaintext export option in v1** (D3).
2. Password step: user enters a password (validated per §6.1) or taps "generate" for the 6-word passphrase (§6.2).
3. Encrypt: fresh 16-byte salt, fresh nonce, header per §3.3, one-shot AEAD over the payload of §5.
4. Save via the platform file picker, under a filename of the user's choosing. The app treats the destination as hostile (§2) from the moment of write.
5. After a successful export, the wallet marks backup status with the current date (feeds the deletion gate, §7.3). "Verified" status requires an actual restore test — a status the UI SHOULD encourage but MAY defer.

### 7.2 Restore (import)

1. User picks the file and enters its password.
2. **Gate (D1):** if a wallet already exists on the device, restore MUST refuse. The user must explicitly delete the existing wallet first — deletion is a restore prerequisite. No "merge", no "overwrite", no bypass.
3. Parse header → derive key (§4) → AEAD decrypt/verify. Any failure (wrong password, corrupted header, truncated file) produces the same generic failure message; the UI MUST NOT distinguish "wrong password" from "corrupt file" to avoid an oracle, though §9 vectors document both internally.
4. Validate the BIP-139 section as a standalone BIP-139 export before committing anything.
5. Onboard from the secrets-block descriptor via the restore-by-pasted-descriptor path (the same code path as pasting an `sp()` descriptor at onboarding; the spend key is inside the descriptor).
6. Restore is a **full-state restore from the file alone** — the seed phrase is not required, and no rescan is needed to reach scan state (BIP-139 carries it; D9). The user's seed phrase remains independently valid afterwards.

**Restore promise (normative, closes §10 (d)):** a successful file restore MUST leave the wallet in the following state, with no rescan and no network dependency beyond ordinary chain sync for *new* transactions:

- **Funds and addresses:** every address derived up to the backup point, with its key material, is restored exactly.
- **Scan state:** the BIP-139 section restores the scan position and labels; scanning resumes from the backup point — nothing before it is re-scanned, nothing after it is missed.
- **Transaction history:** all transactions recorded at backup time (with their `tweak`/`sp_label` attribution per BIP-139) are restored as if the device had lived through them.
- **Labels:** all BIP-329 / `bip352_labels` entries in the BIP-139 payload are restored.
- **Contacts and settings:** only if the optional §5.3 section is present; its absence is not an error.

The seed-rescan bad-case path (§2, scenario 2) restores **funds and addresses only** — it cannot recover labels, contacts, or the recorded transaction view beyond what rescan rediscovers. UI copy MUST keep this asymmetry visible: file restore = "everything, exactly as it was"; seed restore = "your bitcoin, not your history."

**TODO (spec text needed):** ~~the exact wording of the full-state-restore promise~~ RESOLVED above (2026-11-13); the paragraph is normative and §10 (d) is closed.

### 7.3 Deletion gate (D10)

The wallet-deletion screen MUST display the current backup status in one of three states: **none / exists / verified (with date)**. When no verified backup exists, the screen requires a **typed acknowledgment** (the user types a fixed phrase, e.g. the wallet name, to proceed). The gate **warns hard and refuses nothing**: it never blocks deletion outright, because a refusal would push users to wipe the app via OS settings — with no warning at all. The typed acknowledgment is friction, not a lock.

---

## 8. Escrow v2 — summary and forward compatibility (D6, D7, D12)

This section is a summary for forward-compatibility review only. **Out of scope for v1.** The full escrow/Soroban service design lives in its own decision record (D7) and will get its own spec; the ONLY v1 deliverable from it is the header reservation (§3.3).

The v2 model, as locked:

1. **Donation shared secret.** The user sends a plain silent payment "donation" to an escrow SP address. The resulting shared secret `s_i` becomes a backup secret. No marker, no OP_RETURN, zero on-chain tell beyond an ordinary payment.
2. **Combiner.** The file encryption key becomes `f(s_i, password)` (§4.1) — both factors required. The cleartext authenticated header carries the anchor `txid_i` and `H(s_i)` (never `s_i` itself).
3. **Stateless escrow.** On a recovery request carrying `(txid_i, H(s_i))`, the escrow recomputes `s_i` from chain data plus its scan key, verifies the hash, and releases `s_i` over Soroban (durable profile, no TTL, signature-gated dialogs). No database, no registration.
4. **Multi-escrow.** N donations → N `(txid, H(s))` pairs in the header; any single pair suffices. This is why the header reservation is a counted array, not a fixed pair.
5. **Escrow-dead autonomous recovery.** If every escrow dies, the user restores the seed, rescans, finds their own donation transaction, and recomputes `a` — the sender key, which per BIP-352 is the **sum of the input private keys** — then derives `s_i` and decrypts. Fully autonomous; no third party needed. (Constraint recorded in D7: the donation transaction must contain only the user's inputs — a CoinJoin'd donation breaks recomputability.)
6. **Release policy.** Proof-of-file `(txid, H(s))` only: the requester proves possession of the file without knowing `s_i`. "Lost everything but the password" is declared a dead scenario by ruling — no rescue is designed for it.

What v1 guarantees for this: header space for N pairs, KDF params as header-driven values, and a versioned HKDF purpose string (§4). Nothing more.

---

## 9. Test vectors

BIP-139 currently has no published test vectors; Dana will generate its own and **publish them upstream** (against the BIP-139 draft) as well as in this repository. Vectors are self-generated from a fixed set of test keys and MUST be produced by the reference implementation, not hand-computed.

Required vectors (one file each, with full header hex, plaintext section hex, password, and expected outcomes):

1. **Minimal payload.** BIP-139 section only (no secrets block is impossible per §5 — REQUIRED sections are both present; "minimal" here means: empty optional section, smallest valid BIP-139 export, e.g. a single `bip392` account with no labels).
2. **With secrets block.** Standard two-section file: BIP-139 payload + secrets block with a test `sp()` descriptor.
3. **With optional section.** All three sections present, exercising companion fields.
4. **Wrong-password decryption failure.** Same file as vector 2, decrypt with an incorrect (policy-valid) password: AEAD tag mismatch, no partial plaintext, defined error code.
5. **Corrupted-header-AAD failure.** Same file as vector 2 with one flipped bit in a non-magic header byte (e.g. `argon2_t`): tag verification fails against the tampered AAD, defined error code. A companion case with a flipped bit in the magic bytes documents the early parse-reject path (§3.2).

Each vector MUST state: Argon2id params, salt, nonce, the exact AES/XChaCha selection (`cipher_id`), and the derived AEAD key — the last one so implementers can debug KDF drift independently of AEAD issues.

---

## 10. Open items

These are unresolved and MUST NOT be presented as decided anywhere in implementation or docs:

- **(a) ~~Cipher final ruling~~ RESOLVED (2026-11-13).** Founder ruled: XChaCha20-Poly1305 via the RustCrypto `chacha20poly1305` crate. AES-256-GCM retained as reader-side-only `cipher_id = 0x02`. See §3.4 for the decision text, the NCC Group audit basis, and the `cargo audit` pre-merge requirement.
- **(b) ~~Argon2id low-end verification~~ CLOSED as default-adopted (2026-11-14).** Founder ruled: ship with the default **m = 64 MiB, t = 3, p = 1** (RFC 9106 second recommended profile). Published baselines (§6.3.1) indicate it clears all non-Go Android devices and 1 GB Go devices; only 512 MB-era Go devices are marginal, and the §6.3.2 encrypt-side fallback covers those without a format change. The Android Go emulator verification run remains a non-blocking follow-up (staged per skill `devops/android-emulator-aarch64-host`); if it ever contradicts the baselines, the header-serialized KDF params allow re-tuning without breaking v1 files.
- **(c) ~~Exact combiner `f(s_i, password)` for v2~~ RESOLVED (2026-11-13).** Founder ruled: two-pass Argon2id cascade — password pass nested inside the escrow pass (`key_material = Argon2id(s_i || H(k_pass), salt_2, …)`), full definition normative in §4.1.1. XOR construction rejected. v1 unaffected; the v1 header reservation remains sufficient.
- **(d) ~~Full-state restore promise wording~~ RESOLVED (2026-11-13).** Normative paragraph added in §7.2: file restore = funds + addresses + scan state + history + labels (+ contacts/settings if the optional section is present), no rescan; seed restore = funds and addresses only. UI copy must keep the asymmetry visible.
