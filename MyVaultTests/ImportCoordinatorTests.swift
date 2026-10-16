import XCTest
@testable import MyVault

/// Exercises the Photos-original removal gate around `ImportCoordinator` with a
/// mocked photo library: the ordering invariant is that an original is only ever
/// offered for removal after its vault copy verified *and* persisted, and that
/// nothing is ever deleted from the vault or Photos without an explicit confirm.
/// Records what the coordinator asked for instead of touching the real photo
/// library. `deleteOriginals` returns a canned outcome.
private final class MockPhotoLibrary: PhotoLibraryDeleting {
    var accessLevel: PhotoAccess = .authorized
    var deleteOutcome = OriginalDeleteOutcome()
    private(set) var deleteCalls: [[String]] = []
    private(set) var pickerPresentations = 0

    func access() -> PhotoAccess { accessLevel }
    func requestAuthorization() async -> PhotoAccess { accessLevel }
    func deleteOriginals(_ identifiers: [String]) async -> OriginalDeleteOutcome {
        deleteCalls.append(identifiers)
        return deleteOutcome
    }
    func presentLimitedLibraryPicker() -> Bool {
        pickerPresentations += 1
        return accessLevel == .limited
    }
}

@MainActor
final class ImportCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private func importResult(_ status: ImportItemStatus, asset: String?, hash: String) -> ImportItemResult {
        ImportItemResult(
            status: status, assetIdentifier: asset, storedName: "x.mvenc", fileName: "x.jpg",
            mediaType: "photo", fileSize: 1, contentHash: hash, width: 0, height: 0,
            duration: 0, capturedAt: nil, errorMessage: nil
        )
    }

    private func waitUntil(_ condition: () -> Bool, description: String) async {
        var waited: UInt64 = 0
        while !condition(), waited < 2_000_000_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5_000_000
        }
        XCTAssertTrue(condition(), description)
    }

    // MARK: - Removal eligibility gate

    func testOnlyVerifiedAndPersistedItemsAreEligibleForRemoval() {
        let verified = importResult(.imported, asset: "asset-verified", hash: "hash-verified")
        // Import verified but the SwiftData row failed to persist: the original
        // must NOT be offered, there is no retrievable vault copy. That is expressed
        // by *omitting* this item's hash from `persistedHashes` below — the set is
        // the ground truth, so listing it here would contradict the fixture.
        let persistFailed = importResult(.imported, asset: "asset-persist-failed", hash: "hash-persist-failed")
        let failed = ImportItemResult.failure(assetIdentifier: "asset-failed", fileName: "x.jpg", fileSize: 1, hash: "hash-failed", message: "nope")
        let duplicate = importResult(.duplicate, asset: "asset-duplicate", hash: "hash-duplicate")
        // Verified and persisted, but the picker never gave us an identifier:
        // there is no handle to delete it by. It *does* appear in the persisted set
        // and is still excluded, which is the point of the second assertion.
        let noIdentifier = importResult(.imported, asset: nil, hash: "hash-no-identifier")

        let eligible = ImportCoordinator.removalEligibleIdentifiers(
            [verified, persistFailed, failed, duplicate, noIdentifier],
            persistedHashes: ["hash-verified", "hash-no-identifier"]
        )

        XCTAssertEqual(eligible, ["asset-verified"])

        // And the complement: an item whose hash *is* persisted and whose identifier
        // exists must be eligible, so the gate cannot pass by excluding everything.
        let eligibleAgain = ImportCoordinator.removalEligibleIdentifiers(
            [verified], persistedHashes: ["hash-verified"]
        )
        XCTAssertEqual(eligibleAgain, ["asset-verified"])
    }

    // MARK: - Confirm path

    func testDeletionFailureProducesOriginalsRemainNotice() async {
        let mock = MockPhotoLibrary()
        mock.deleteOutcome = OriginalDeleteOutcome(deleted: [], unavailable: ["asset-b"], failed: ["asset-a"], errorMessage: "refused")
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.removalRequest = ImportCoordinator.RemovalRequest(assetIdentifiers: ["asset-a", "asset-b"], limitedAccess: false)
        coordinator.confirmRemoval()

        await waitUntil({ coordinator.notice != nil }, description: "removal outcome notice should appear")

        // Exactly the confirmed assets were passed to Photos — nothing else.
        XCTAssertEqual(mock.deleteCalls, [["asset-a", "asset-b"]])
        XCTAssertEqual(coordinator.notice?.title, "Kept the originals")
        XCTAssertEqual(coordinator.notice?.isError, true)
        XCTAssertNil(coordinator.removalRequest)
        XCTAssertTrue(coordinator.pendingRemovalIdentifiers.isEmpty)
        XCTAssertEqual(coordinator.stage, .idle)
    }

    func testSuccessfulDeletionReportsRemovedNotice() async {
        let mock = MockPhotoLibrary()
        mock.deleteOutcome = OriginalDeleteOutcome(deleted: ["asset-a"], unavailable: [], failed: [])
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.removalRequest = ImportCoordinator.RemovalRequest(assetIdentifiers: ["asset-a"], limitedAccess: false)
        coordinator.confirmRemoval()

        await waitUntil({ coordinator.notice != nil }, description: "removal outcome notice should appear")

        XCTAssertEqual(mock.deleteCalls, [["asset-a"]])
        XCTAssertEqual(coordinator.notice?.title, "Removed from Photos")
        XCTAssertEqual(coordinator.notice?.isError, false)
        XCTAssertNil(coordinator.removalRequest)
    }

    // MARK: - Decline path

    func testKeepOriginalsDeletesNothing() {
        let mock = MockPhotoLibrary()
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.removalRequest = ImportCoordinator.RemovalRequest(assetIdentifiers: ["asset-a", "asset-b"], limitedAccess: false)
        coordinator.keepOriginals()

        XCTAssertTrue(mock.deleteCalls.isEmpty, "keep-originals must never touch Photos")
        XCTAssertNil(coordinator.removalRequest)
        XCTAssertTrue(coordinator.pendingRemovalIdentifiers.isEmpty)
        XCTAssertEqual(coordinator.notice?.title, "Kept in Photos")
        XCTAssertEqual(coordinator.notice?.isError, false)
    }

    // MARK: - Pending removal re-offered once access is granted

    func testGrantedAccessOffersPendingRemovalOfVerifiedAssets() async {
        let mock = MockPhotoLibrary()
        mock.accessLevel = .authorized
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.pendingRemovalIdentifiers = ["asset-1", "asset-2"]
        coordinator.requestPhotosAccess()

        await waitUntil({ coordinator.removalRequest != nil }, description: "pending removal should be re-offered after access is granted")

        XCTAssertEqual(coordinator.removalRequest?.assetIdentifiers, ["asset-1", "asset-2"])
        XCTAssertEqual(coordinator.removalRequest?.limitedAccess, false)
        XCTAssertTrue(coordinator.pendingRemovalIdentifiers.isEmpty)
    }

    func testGrantedAccessWithoutPendingShowsInformationalNotice() async {
        let mock = MockPhotoLibrary()
        mock.accessLevel = .authorized
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.requestPhotosAccess()

        await waitUntil({ coordinator.notice != nil }, description: "granted notice should appear")

        XCTAssertEqual(coordinator.notice?.title, "Photos access granted")
        XCTAssertNil(coordinator.removalRequest)
    }

    // MARK: - Limited-access notice plumbing

    func testLimitedAccessNoticeOffersManageSelectedPhotosAction() async {
        let mock = MockPhotoLibrary()
        mock.accessLevel = .limited
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.requestPhotosAccess()

        await waitUntil({ coordinator.notice != nil }, description: "limited-access notice should appear")

        XCTAssertEqual(coordinator.notice?.action, .manageSelectedPhotos)
        XCTAssertEqual(coordinator.notice?.actionTitle, "Manage Selected Photos")

        coordinator.performNoticeAction()
        XCTAssertEqual(mock.pickerPresentations, 1)
        XCTAssertNil(coordinator.notice)
    }

    func testDeniedAccessNoticeStillOpensSettings() async {
        let mock = MockPhotoLibrary()
        mock.accessLevel = .denied
        let coordinator = ImportCoordinator(photoLibrary: mock)

        coordinator.requestPhotosAccess()

        await waitUntil({ coordinator.notice != nil }, description: "denied-access notice should appear")

        XCTAssertEqual(coordinator.notice?.action, .openSystemSettings)
        XCTAssertEqual(coordinator.notice?.actionTitle, "Open Settings")
    }
}
