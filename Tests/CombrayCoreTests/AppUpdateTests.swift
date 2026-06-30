import XCTest
@testable import CombrayCore

/// The auto-updater's pure logic: numeric version comparison and decoding GitHub's release JSON
/// (tag → version, and picking the right downloadable asset).
final class AppUpdateTests: XCTestCase {

    // MARK: version comparison

    /// A higher patch/minor/major is detected as newer; numeric, not lexical (so 0.10 > 0.9, 0.12.0 > 0.11.1).
    func testNewerVersionsAreDetected() {
        XCTAssertTrue(AppUpdate.isNewer("0.12.0", than: "0.11.1"))
        XCTAssertTrue(AppUpdate.isNewer("0.11.2", than: "0.11.1"))
        XCTAssertTrue(AppUpdate.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertTrue(AppUpdate.isNewer("0.10.0", than: "0.9.0"))   // numeric: 10 > 9 (not "10" < "9")
    }

    /// Equal or older versions are NOT newer (so we never nag a current/ahead app).
    func testEqualOrOlderIsNotNewer() {
        XCTAssertFalse(AppUpdate.isNewer("0.11.1", than: "0.11.1"))
        XCTAssertFalse(AppUpdate.isNewer("0.11.0", than: "0.11.1"))
        XCTAssertFalse(AppUpdate.isNewer("0.9.0", than: "0.10.0"))
    }

    /// A leading "v" on either side is ignored, and missing trailing components count as zero.
    func testLeadingVAndDifferingLengths() {
        XCTAssertTrue(AppUpdate.isNewer("v0.12.0", than: "0.11.1"))
        XCTAssertFalse(AppUpdate.isNewer("v0.11", than: "0.11.0"))    // 0.11 == 0.11.0
        XCTAssertTrue(AppUpdate.isNewer("0.11.1", than: "0.11"))      // 0.11.1 > 0.11.0
    }

    // MARK: release JSON

    private let sampleJSON = """
    {
      "tag_name": "v0.12.0",
      "html_url": "https://github.com/Labern/Combray/releases/tag/v0.12.0",
      "assets": [
        {"name": "Combray.pkg", "browser_download_url": "https://example.com/Combray.pkg"},
        {"name": "Combray.zip", "browser_download_url": "https://example.com/Combray.zip"}
      ]
    }
    """

    /// The release tag decodes and strips its leading "v" into a plain version string.
    func testDecodesTagAndVersion() throws {
        let r = try GitHubRelease.decode(Data(sampleJSON.utf8))
        XCTAssertEqual(r.tagName, "v0.12.0")
        XCTAssertEqual(r.version, "0.12.0")
        XCTAssertEqual(r.assets.count, 2)
    }

    /// The updater picks the `.zip` asset (the bundle it swaps), not the `.pkg`.
    func testPicksZipAssetURL() throws {
        let r = try GitHubRelease.decode(Data(sampleJSON.utf8))
        XCTAssertEqual(r.assetURL(suffix: ".zip")?.absoluteString, "https://example.com/Combray.zip")
        XCTAssertEqual(r.assetURL(suffix: ".pkg")?.absoluteString, "https://example.com/Combray.pkg")
    }

    /// A release that carries no matching asset returns nil (older .pkg-only releases can't self-update).
    func testMissingAssetReturnsNil() throws {
        let json = """
        {"tag_name":"v0.11.1","html_url":"https://x","assets":[
          {"name":"Combray.pkg","browser_download_url":"https://example.com/Combray.pkg"}]}
        """
        let r = try GitHubRelease.decode(Data(json.utf8))
        XCTAssertNil(r.assetURL(suffix: ".zip"))
    }
}
