import XCTest
@testable import Multiplex

final class NewSessionPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let script = SessionScript(name: "venv", body: "source .venv/bin/activate")
    private lazy var host = Host(
        name: "devbox", hostname: "devbox.example.com", username: "dev",
        sessionScripts: [script]
    )

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
        XCTAssertNil(preferences.rememberedScript(for: host))
    }

    func testPersistsRememberedAgentAcrossInstances() {
        NewSessionPreferences(defaults: defaults).save(
            remembersLastLaunch: true,
            agent: .codex,
            script: nil,
            hostID: host.id
        )

        let reloaded = NewSessionPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.remembersLastLaunch)
        XCTAssertEqual(reloaded.rememberedAgent, .codex)
    }

    func testPersistsRememberedPiAcrossInstances() {
        NewSessionPreferences(defaults: defaults).save(
            remembersLastLaunch: true,
            agent: .pi,
            script: nil,
            hostID: host.id
        )

        let reloaded = NewSessionPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.remembersLastLaunch)
        XCTAssertEqual(reloaded.rememberedAgent, .pi)
    }

    func testCanRememberShellOnly() {
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(
            remembersLastLaunch: true, agent: nil, script: nil, hostID: host.id
        )

        XCTAssertTrue(preferences.remembersLastLaunch)
        XCTAssertNil(preferences.rememberedAgent)
        XCTAssertNil(preferences.rememberedScript(for: host))
    }

    func testDisablingClearsStaleAgent() {
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(
            remembersLastLaunch: true, agent: .claudeCode,
            script: script, hostID: host.id
        )
        preferences.save(
            remembersLastLaunch: false, agent: .claudeCode,
            script: script, hostID: host.id
        )

        XCTAssertFalse(preferences.remembersLastLaunch)
        XCTAssertNil(preferences.rememberedAgent)
        XCTAssertNil(defaults.string(forKey: "newSession.lastAgent"))
        XCTAssertNil(preferences.rememberedScript(for: host))
        // The whole per-host map goes, not just this host's entry.
        XCTAssertNil(defaults.dictionary(forKey: "newSession.lastScripts"))
    }

    func testRemembersScriptPerHost() {
        let otherHost = Host(
            name: "prod", hostname: "prod.example.com", username: "dev",
            sessionScripts: [SessionScript(name: "warm caches", body: "make warm")]
        )
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(
            remembersLastLaunch: true, agent: nil, script: script, hostID: host.id
        )

        let reloaded = NewSessionPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.rememberedScript(for: host)?.id, script.id)
        // Script ids are host-scoped; another host has no memory.
        XCTAssertNil(reloaded.rememberedScript(for: otherHost))
    }

    func testRememberingNoneClearsTheHostEntry() {
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(
            remembersLastLaunch: true, agent: nil, script: script, hostID: host.id
        )
        preferences.save(
            remembersLastLaunch: true, agent: nil, script: nil, hostID: host.id
        )

        XCTAssertNil(preferences.rememberedScript(for: host))
    }

    func testDeletedScriptFailsSoftToNone() {
        let preferences = NewSessionPreferences(defaults: defaults)
        preferences.save(
            remembersLastLaunch: true, agent: nil, script: script, hostID: host.id
        )

        var edited = host
        edited.sessionScripts = []
        XCTAssertNil(preferences.rememberedScript(for: edited))
    }
}
