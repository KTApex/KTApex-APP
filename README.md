# MyVault — Private memories. Special moments.

A premium, privacy-focused native iOS app with two core purposes:

1. **Secure private photo/video vault** — AES-GCM encrypted on-device storage, albums, trash, search, storage management.
2. **Special-day memory & reminder system** — birthdays, anniversaries, countdowns, local notifications, home-screen widget.

100% offline-capable. No account, no backend, no tracking SDKs, no Firebase.

## Requirements

- macOS with Xcode 16.2+ (macOS 15 runner for CI)
- iOS 17.0+ deployment target
- Swift 5.9, SwiftUI, SwiftData
- Apple Developer account (only needed for device testing, TestFlight, App Store)

> **Apple signing limitation (read this first):** GitHub Actions cannot bypass Apple code signing.
> Unsigned `xcodebuild build/test` works on CI with `CODE_SIGNING_ALLOWED=NO`.
> This repo ships **one** workflow, `ios-unsigned-ipa.yml`, which uses no Apple credentials
> at all: it produces an **unsigned** IPA that must be re-signed (AltStore/Sideloadly/Xcode)
> before it can be installed. A signed-IPA archive workflow is no longer included — see
> "Signed IPA (optional)" below if you want to re-add one.

## Project structure

```text
MyVault/
├── App/                  MyVaultApp, AppRouter (AppState), RootView
├── Core/Theme            ThemeManager, accent system, typography, tokens
├── Core/Components       MVPrimaryButton, MVCard, MVEmptyState, MVLoadingView, CountdownRing
├── Core/Extensions       Date/String helpers
├── Core/Utilities        Haptics, PrivacyShield (app-switcher blur)
├── Models/               VaultAlbum, VaultMedia, SpecialDay, ReminderConfiguration, AppSettings, BackupMetadata
├── Features/Onboarding   5-screen first-launch flow
├── Features/Authentication  Lock screen (biometrics + PIN), PIN setup
├── Features/Home         Dashboard + tab bar
├── Features/Vault        Encrypted vault grid, import, search/filter, trash
├── Features/Albums       Albums list + detail
├── Features/MediaViewer  Full-screen viewer, zoom, video, favorite, trash
├── Features/SpecialDays  List, cards, editor, detail
├── Features/Settings     Security, notifications, appearance, storage, privacy, backup, about
├── Services/             Keychain, Encryption, VaultStorage, Auth, PIN, PhotoLibrary,
│                         Notification, CountdownEngine, ThumbnailCache, Storage, Backup
├── Widgets/              Upcoming Special Day widget (title only — never vault media)
├── Intents/              Open Vault / Show Next Special Day App Intents
├── Info.plist            Face ID, Photos, Notifications usage descriptions
└── MyVault.entitlements  App Groups + iCloud (opt-in backup)
MyVaultTests/              Countdown, encryption, storage/duplicates, PIN policy,
                           backup create/restore/rollback, Photos-removal gating
MyVaultUITests/            Onboarding, tabs, special-day flow, vault, settings
MyVaultWidget/Info.plist  Widget extension plist
.github/workflows/        ios-unsigned-ipa.yml (tests + unsigned IPA artifact)
ExportOptions.plist        Template for a signed-archive workflow (see "Signed IPA")
```

## Unsigned IPA (no Apple credentials)

`ios-unsigned-ipa.yml` produces an installable-after-resigning artifact without any
Apple Developer account, certificate or provisioning profile:

1. it runs the **unit tests** on a simulator first — an IPA is never packaged from a
   tree whose tests fail;
2. it builds the Release device binary with `CODE_SIGNING_ALLOWED=NO` (ad-hoc signing is
   rejected by recent SDKs, so signing is skipped entirely);
3. it packages `Payload/MyVault.app` into `MyVault-unsigned.ipa` and verifies the
   archive really contains the app bundle;
4. it uploads `MyVault-unsigned-ipa` as a workflow artifact.

The unsigned IPA **cannot be installed directly**. Re-sign it with AltStore, Sideloadly
or Xcode (free Apple ID) before sideloading. Keychain access works after re-signing
because the app is signed with a real identity at that point; an *unsigned* build gets
`errSecMissingEntitlement` (-34018) from every Keychain call.

The workflow triggers on pushes to `main`, `master` and `feat/**`, plus manual dispatch,
and uses `permissions: contents: read` with per-ref concurrency cancellation. It never
reads a secret.

## Security model

- Photos/videos are encrypted with **AES-GCM (CryptoKit)** before being written to
  `Application Support/vault/*.mvenc`. Metadata only in SwiftData.
- The 256-bit vault key is generated with `UInt8.random` and stored in the **Keychain**
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Never in SwiftData, never hardcoded.
- Optional PIN is stored as **salted SHA-256 verifier** in the Keychain (raw PIN never stored).
  5 failed attempts → 60-second lockout.
- Biometrics via **LocalAuthentication** (device owner policy). No biometric data stored.
- Backgrounding shows a blur shield so the app switcher never reveals private media.
- Auto-lock: immediately / 30s / 1m / 5m.
- Decrypted plaintext only ever exists in `SecureScratch` (complete file protection,
  excluded from backup) and is removed when the operation finishes. The thumbnail
  cache holds decrypted pixels in memory only, and is cleared on lock and backgrounding.

### Photos → Vault removal ordering

Removing an original from Apple Photos is gated on a full round-trip verification:

1. the picked bytes are read (file representation preferred over in-memory), sniffed
   and encrypted;
2. the ciphertext is read back through the real decrypt path and its SHA-256 is
   compared with the plaintext hash;
3. the SwiftData row is persisted — an item whose row fails to save is *not* eligible;
4. **only then** is the user asked whether to remove the original, and only the
   verified-and-persisted assets are offered.

A failed removal never touches the vault copy, and the original is never deleted
before its vault copy verifies. Limited/denied Photos access, deletion refusal and
partially visible assets are all reported as partial outcomes rather than silently
ignored.

### Portable encrypted backups (`.mvbackup`)

`Settings → Backup & Restore` produces `MyVault_Backup_YYYY-MM-DD_HH-mm.mvbackup`.
The file is **one authenticated encrypted stream**, not a plaintext ZIP:

```text
"MVBK"            4 bytes   magic
formatVersion     1 byte    newer versions are refused before a password is asked
kdf               1 byte    1 = PBKDF2-HMAC-SHA256 (Apple CommonCrypto)
reserved          2 bytes   must be zero
iterations        4 bytes   big-endian (10,000 … 5,000,000 enforced)
saltLength        2 bytes   big-endian
salt              n bytes   SecRandomCopyBytes
── body ──────────────────── AES-GCM sealed 4 MiB parts
entryCount        4 bytes   inside the encrypted payload
entry*                      name, sizes, then one or more sealed parts
```

- The password is stretched with **PBKDF2-HMAC-SHA256** (250,000 iterations by default)
  and a fresh random salt — CryptoKit has no password KDF, so Apple's own implementation
  is used rather than a third-party one.
- The header is passed as AES-GCM **associated data**, and each part additionally binds
  its `(entry, part)` position, so a modified header, a reordered part or a duplicated
  part cannot authenticate.
- The whole file is written with complete file protection, built at a temporary path,
  **verified by re-opening it**, and only then renamed to its final name.
- Restore is **transactional**: the payload is staged and validated first, ciphertext is
  written without being referenced, every row is inserted in a single save, and any
  failure removes exactly what the restore created. Existing vault data is never
  modified or deleted — items already present are matched by content hash and skipped.
- Nothing security-relevant is in the backup: no PIN verifier, no vault key, no
  lockout state. The backup password is never written to the file, `UserDefaults` or
  the Keychain.

- Trash: 30-day retention with restore, permanent delete, auto-purge of expired items.
- Notifications are **local only** (`UserNotifications`); tapping one deep-links to the event.

## Residual risks (what this design does *not* claim)

No app is unhackable. These are the real, known limits:

- **A weak backup password is the weakest link.** The `.mvbackup` file can be copied
  freely, so offline guessing is possible. PBKDF2 with 250,000 iterations makes each
  guess expensive but cannot rescue a short or common password. Pick a long passphrase.
- **An unlocked, jailbroken or compromised device can read decrypted media.** Vault
  ciphertext is protected at rest by AES-GCM and `NSFileProtectionComplete`; while the
  app is unlocked and the key is in memory, a privileged attacker on the device can
  reach plaintext. There is no protection against a live kernel-level attacker.
- **Screenshots / screen recording of the viewer are not blocked.** The app-switcher
  shield hides the app when backgrounded, but `UIScreen` capture during use is not
  prevented, because iOS does not offer a supported API to do it reliably.
- **The vault key is `ThisDeviceOnly`.** That is deliberate: a stolen Keychain backup or
  iTunes/iCloud device backup cannot be used to decrypt the vault on another device. The
  consequence is that the *only* way to move media is a `.mvbackup` — which needs its
  password, and which MyVault cannot recover.
- **Sharing necessarily produces brief plaintext on disk** in scratch space (complete
  file protection, excluded from backup, removed after the share sheet finishes and
  again at next launch). A share left in flight when the device is compromised during
  that window is exposed as any plaintext file would be.
- **Backups contain the user's original media** in encrypted form. A backup made before
  a "delete permanently" still contains that media — restore does not know it was deleted.
- **No protection against a malicious OS-level backup or a compromised build.** Code
  signing protects the binary's integrity; an attacker who can install their own build
  with the same signing identity is outside this model.
- **`SwiftData` metadata is not itself encrypted**; it holds file names, dates, sizes and
  hashes, not media bytes. The database file relies on the app sandbox and file
  protection, not on application-level encryption.
- **Photos removal moves originals to Apple's "Recently Deleted"**, where they remain
  recoverable for up to 30 days. MyVault cannot force permanent erasure of a Photos asset.


## Local build

1. Open `MyVault.xcodeproj` in Xcode.
2. Set your **Team** and **Bundle Identifier** (Signing & Capabilities).
3. Add a `AppIcon-1024.png` (1024×1024, no transparency) to
   `MyVault/Resources/Assets.xcassets/AppIcon.appiconset/` — see its `README.txt`.
4. Select an iPhone simulator → **Run** (`⌘R`).
5. Tests: **Product → Test** (`⌘U`).

If you add/remove Swift files, regenerate the project:

```bash
python3 gen_project.py
```

This rewrites `MyVault.xcodeproj/project.pbxproj` and patches the shared scheme IDs.

## GitHub setup + CI

1. Push this folder to a GitHub repo.
2. `ios-unsigned-ipa.yml` runs automatically on pushes to `main`, `master` and `feat/**`,
   and manually via `workflow_dispatch`:
   unit tests on a simulator → Release device build (`CODE_SIGNING_ALLOWED=NO`) →
   package `Payload/` → verify the IPA contains the app bundle and its executable →
   upload the `MyVault-unsigned-ipa` artifact.

That single workflow is the whole CI story: it builds, runs the **unit** tests, and
produces an installable-after-resigning IPA with no secrets configured. It needs
nothing under *Settings → Secrets*.

> **UI tests are no longer run in CI.** The previous `ci.yml` also ran
> `MyVaultUITests`; that workflow was removed, so `ios-unsigned-ipa.yml` covers
> `MyVaultTests` only. Run UI tests locally with `⌘U`, or re-add a UI-test job
> (`-only-testing:MyVaultUITests`) if you want them gated again.

## Signed IPA (optional)

No signed-archive workflow is included, because it cannot work without your own Apple
credentials. If you want one, re-add a `workflow_dispatch` workflow that:

1. validates the signing secrets below and fails loudly if any are missing;
2. creates a temporary keychain and imports `BUILD_CERTIFICATE_BASE64`;
3. installs `PROVISIONING_PROFILE_BASE64` (+ the widget profile);
4. runs `xcodebuild archive` then `xcodebuild -exportArchive` with an `ExportOptions.plist`
   whose `method` you pass as an input (`app-store` / `ad-hoc` / `development`);
5. uploads the IPA artifact and deletes the temporary keychain in an `always()` step.

Secrets such a workflow would need:

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64 of your distribution `.p12` |
| `P12_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string for the temp CI keychain |
| `PROVISIONING_PROFILE_BASE64` | Base64 of the matching `.mobileprovision` |
| `WIDGET_PROVISIONING_PROFILE_BASE64` | *Optional* — Base64 of a profile for `<BUNDLE_IDENTIFIER>.widget`; the archive embeds the widget extension, so without it (or Xcode-managed signing) the widget cannot be signed |
| `APPLE_TEAM_ID` | Your 10-char Team ID |
| `BUNDLE_IDENTIFIER` | e.g. `com.yourname.myvault` |

These are never hardcoded or committed — reference them only through `${{ secrets.… }}`
and pass them via `env:`; never `echo` a secret. Create them under
**Settings → Secrets and variables → Actions**. `.gitignore` already excludes
`*.p12`, `*.mobileprovision`, `.env`, `DerivedData/`, `build/`.

## TestFlight workflow

1. Re-add the signed-IPA workflow described above (there is none in the repo right now).
2. Run it with an `app-store` export method and download the resulting IPA artifact
   (or extend it with a `notarytool`/`altool` upload using your App Store Connect key).
3. Alternatively archive locally and use Xcode Organizer → Distribute → TestFlight.

## Troubleshooting

- **No signing identity**: CI build uses `CODE_SIGNING_ALLOWED=NO` (simulator only). Device/IPA builds need a Team + provisioning profile.
- **Face ID in simulator**: Features → Face ID → Enrolled (simulator has no real biometrics; device passcode fallback applies).
- **Notifications not firing**: check Settings → permission status; denied → "Open Settings" button.
- **iCloud backup toggle**: requires iCloud sign-in; otherwise the app stays local-only. Ciphertext-only blobs are synced; the Keychain key never leaves the device, so a new device needs a key transfer (documented in-app).
- **Feb 29 birthdays**: clamped to Feb 28 in non-leap years; countdown uses `Calendar` math, not 365-day division.
- **Widget shows "No special days"**: the widget reads the shared App Group `group.com.myvault.shared`. For on-device builds, that App Group must be registered to **your** Apple Developer account (and its prefix replaced in `MyVault.entitlements` + `MyVaultWidget/MyVaultWidget.entitlements` + the `WidgetSummaryService` suite name + the widget's `UserDefaults(suiteName:)`). On the simulator without signing, the widget simply shows its placeholder.

## Known iOS limitations

- Original Photos-library deletion always requires explicit user confirmation via Photos APIs — the app never deletes silently. After import you are offered "Remove originals from Photos?" and nothing is deleted without confirmation.
- Widgets cannot show vault media (privacy) — only the next event title/countdown, fed via the shared App Group.
- App Intents expose navigation only, never decrypted media.
- Tapping a Special Day notification deep-links to that event (set on the app's `UNUserNotificationCenter` delegate); this works in foreground and background but a killed app launch is handled once the user unlocks.
- The project file and shared scheme are generated by `gen_project.py`; running it rewrites both in lock-step so the scheme's target IDs always match.
