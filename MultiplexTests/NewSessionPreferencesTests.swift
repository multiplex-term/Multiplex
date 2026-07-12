import XCTest
@testable import Multiplex

final class NewSessionPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NewSessionPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToNotRemembering() {
        let preferences = NewSessionPreferences(defaults: defaults)

        XCTAssertFalse(preferences.remembersLastLaunch)
        XCTAssertNil(preferences.rememberedAgent)
    }

    func testPersistsRememberedAgentAcrossInstances() {
        NewSessionPreferences(defaults: defaults).save(
            remembersLastLaunch: true,
            agent: .codex
        )

        let reloaded = NewSessionPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.remembersLastLaunch)
        XCTAssertEqual(reloaded.rememberedAgent, .codex)
    }

    func testCanRememberShellOnly() {
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(remembersLastLaunch: true, agent: nil)

        XCTAssertTrue(preferences.remembersLastLaunch)
        XCTAssertNil(preferences.rememberedAgent)
    }

    func testDisablingClearsStaleAgent() {
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(remembersLastLaunch: true, agent: .claudeCode)
        preferences.save(remembersLastLaunch: false, agent: .claudeCode)

        XCTAssertFalse(preferences.remembersLastLaunch)
        XCTAssertNil(preferences.rememberedAgent)
        XCTAssertNil(defaults.string(forKey: "newSession.lastAgent"))
    }
}
