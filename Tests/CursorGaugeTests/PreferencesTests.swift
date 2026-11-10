import XCTest
@testable import CursorGauge

final class PreferencesTests: XCTestCase {
    private static let standardSuite = "cursor-gauge-tests.standard"
    private static let applicationSuite = "cursor-gauge-tests.application"

    override func setUp() {
        super.setUp()
        Self.removeDomains()
    }

    override func tearDown() {
        Self.removeDomains()
        super.tearDown()
    }

    private static func removeDomains() {
        // The suite domains are test-only; remove them so real user defaults are never
        // read or written by these tests.
        UserDefaults.standard.removePersistentDomain(forName: standardSuite)
        UserDefaults.standard.removePersistentDomain(forName: applicationSuite)
    }

    func testAppBundleResolvesStandardDefaults() {
        let standard = UserDefaults(suiteName: Self.standardSuite)!
        let application = UserDefaults(suiteName: Self.applicationSuite)!
        let resolved = Preferences.defaultStore(
            bundleIdentifier: Preferences.applicationBundleIdentifier,
            standard: standard, application: application
        )
        XCTAssertTrue(resolved === standard)
    }

    func testUnbundledProcessResolvesApplicationDomain() {
        let standard = UserDefaults(suiteName: Self.standardSuite)!
        let application = UserDefaults(suiteName: Self.applicationSuite)!
        let resolved = Preferences.defaultStore(
            bundleIdentifier: nil, standard: standard, application: application
        )
        XCTAssertTrue(resolved === application)
    }

    func testOtherBundleIdentifierResolvesApplicationDomain() {
        let standard = UserDefaults(suiteName: Self.standardSuite)!
        let application = UserDefaults(suiteName: Self.applicationSuite)!
        let resolved = Preferences.defaultStore(
            bundleIdentifier: "com.example.other", standard: standard, application: application
        )
        XCTAssertTrue(resolved === application)
    }

    func testUnbundledFallsBackToStandardWhenApplicationDomainMissing() {
        let standard = UserDefaults(suiteName: Self.standardSuite)!
        XCTAssertTrue(
            Preferences.defaultStore(bundleIdentifier: nil, standard: standard, application: nil)
                === standard
        )
    }
}
