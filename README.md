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
> A **signed IPA** requires your own Apple Developer credentials supplied as GitHub Secrets.
> Without valid secrets, the `ios-release.yml` workflow fails at the "Validate signing secrets" step by design.

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
MyVaultTests/              Countdown, encryption, storage/duplicates, PIN policy
MyVaultUITests/            Onboarding, tabs, special-day flow, vault, settings
MyVaultWidget/Info.plist  Widget extension plist
.github/workflows/        ci.yml (build+test), ios-release.yml (signed IPA)
ExportOptions.plist        Template; release workflow injects method + teamID
```

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
- Trash: 30-day retention with restore, permanent delete, auto-purge of expired items.
- Notifications are **local only** (`UserNotifications`); tapping one deep-links to the event.

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
2. `ci.yml` runs automatically on pushes/PRs to `main`/`master`:
   checkout → select Xcode → clean build (unsigned) → `xcodebuild test` → upload `.xcresult`.
3. `ios-release.yml` is manual (`workflow_dispatch`, pick `app-store` / `ad-hoc` / `development`):
   validate secrets → temp keychain → import cert → install profile → archive → export IPA → upload artifact → delete keychain.

## GitHub Secrets (release only)

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64 of your distribution `.p12` |
| `P12_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string for the temp CI keychain |
| `PROVISIONING_PROFILE_BASE64` | Base64 of the matching `.mobileprovision` |
| `WIDGET_PROVISIONING_PROFILE_BASE64` | *Optional* — Base64 of a profile for `<BUNDLE_IDENTIFIER>.widget`; the archive embeds the widget extension, so without it (or Xcode-managed signing) the widget cannot be signed |
| `APPLE_TEAM_ID` | Your 10-char Team ID |
| `BUNDLE_IDENTIFIER` | e.g. `com.yourname.myvault` |

**Optional — App Store Connect API (only if you extend the workflow to upload to TestFlight/App Store):**

| Secret | Purpose |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | Key ID from your App Store Connect API key |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from the App Store Connect API key |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The `.p8` private key contents (never commit it) |

These are **not required** for IPA generation (only for the optional upload step), and are never
hardcoded or committed — they are referenced only through `${{ secrets.… }}`.

Create them under **Settings → Secrets and variables → Actions**. Never commit these files —
`.gitignore` already excludes `*.p12`, `*.mobileprovision`, `.env`, `DerivedData/`, `build/`.

Secrets are only referenced via `${{ secrets.… }}` and passed through `env:` — the workflows
never `echo` secret values.

## TestFlight workflow

1. Run `ios-release.yml` with `app-store` method.
2. Download the IPA artifact (or extend the workflow with `notarytool`/`altool` upload via
   `APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID` / `APP_STORE_CONNECT_PRIVATE_KEY`).
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
