import Foundation
import UniformTypeIdentifiers

/// The Uniform Type Identifier for MyVault's portable backup file.
///
/// The identifier is *exported* by the app (`UTExportedTypeDeclarations` in
/// `Info.plist`), which is what lets iOS resolve the `mvbackup` extension. Without
/// that declaration the Files picker cannot identify the file: it renders the
/// backup greyed out, so the user can see it but not select it. Keeping the
/// identifier in one constant means the plist, the picker and the tests cannot
/// drift apart.
extension UTType {
    /// `com.ktapex.myvault.backup` — "MyVault Backup", extension `mvbackup`.
    ///
    /// The `conformingTo: .data` argument must match `UTTypeConformsTo` in the plist.
    /// Declaring the parent in both places keeps the Swift type and the system's view of
    /// it identical; if they diverge, `UTType.myVaultBackup` can be resolvable while the
    /// file is not treated as data, which breaks matching in the picker.
    static let myVaultBackup = UTType(
        exportedAs: MyVaultBackupType.identifier,
        conformingTo: .data
    )

    /// The raw identifier, for the plist and for predicates.
    static var myVaultBackupIdentifier: String { MyVaultBackupType.identifier }
}

enum MyVaultBackupType {
    /// Must match `UTTypeIdentifier` in `MyVault/Info.plist`.
    static let identifier = "com.ktapex.myvault.backup"
    static let fileExtension = "mvbackup"

    /// Types the importer accepts.
    ///
    /// The app's own type comes first so a real backup is matched directly. `public.data`
    /// is included because a backup that arrived through a provider which lost the
    /// extension — or was renamed by the user — is still a valid backup by *content*,
    /// and `PortableBackupService.inspect` validates the magic bytes immediately after.
    /// Accepting only `.data` (the previous behaviour) was too permissive to identify
    /// our own files and left the system unable to resolve the extension.
    static let importableTypes: [UTType] = [.myVaultBackup, .data]

    /// True when the URL looks like a MyVault backup by extension. Used for
    /// diagnostics and for deciding whether to warn the user, never to reject a file:
    /// content validation is the authority.
    static func looksLikeBackup(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }
}