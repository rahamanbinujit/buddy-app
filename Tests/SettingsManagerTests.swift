import XCTest
@testable import Buddy

final class SettingsManagerTests: XCTestCase {
    private var directory: URL!
    private var manager: SettingsManager!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testProviderSwitchDiscardsCrossProviderPreference() {
        manager.update { $0.preferredModels[ModelProvider.gemini.rawValue] = "gpt-4o" }
        manager.setProvider(.gemini)
        XCTAssertEqual(manager.settings.activeModelId, "gemini-2.5-pro")
        manager.setProvider(.buddyProxy)
        XCTAssertTrue(AvailableModels.models(for: .buddyProxy).contains { $0.id == manager.settings.activeModelId })
    }

    func testProviderSwitchRestoresValidPreference() {
        manager.setProvider(.gemini)
        manager.setModel("gemini-2.5-flash")
        manager.setProvider(.openAI)
        manager.setProvider(.gemini)
        XCTAssertEqual(manager.settings.activeModelId, "gemini-2.5-flash")
    }

    func testInvalidModelCannotBecomeActive() {
        manager.setProvider(.gemini)
        manager.setModel("gpt-4o")
        XCTAssertEqual(manager.settings.activeModelId, "gemini-2.5-pro")
    }

    func testLoadingRepairsMismatchedModelWithoutChangingProvider() {
        manager.update { $0.activeProvider = .gemini; $0.activeModelId = "gpt-4o" }
        let loaded = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))
        XCTAssertEqual(loaded.settings.activeProvider, .gemini)
        XCTAssertEqual(loaded.settings.activeModelId, "gemini-2.5-pro")
    }

    func testSelectionChangesNotifyOnlyWhenConfigurationChanges() {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SettingsManager.modelConfigChanged, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        manager.setProvider(.gemini)
        manager.setProvider(.gemini)
        manager.setModel("gemini-2.5-flash")
        manager.setModel("gemini-2.5-flash")
        manager.setModel("gpt-4o")
        XCTAssertEqual(notifications, 2)
    }
    func testSelectionChangeRetiresRunningSessionAndDetachesCallbacks() {
        let character = BuddyCharacter()
        let session = TestSession()
        character.session = session
        session.onProcessExit = { XCTFail("Retired session must not reset its replacement") }
        session.onText = { _ in XCTFail("Retired session must not append text") }
        character.currentStreamingText = "partial response"
        character.isStartingSession = true
        manager.setProvider(.gemini)
        XCTAssertTrue(session.terminated)
        XCTAssertNil(character.session)
        XCTAssertNil(session.onText)
        XCTAssertNil(session.onProcessExit)
        XCTAssertFalse(character.isStartingSession)
        XCTAssertEqual(character.currentStreamingText, "")
    }

}


private final class TestSession: AgentSession {
    var isRunning = true
    var isBusy = true
    var history: [ChatMessage] = []
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var terminated = false

    func start() {}
    func send(message: String, screenshotBase64: String?) {}
    func terminate() {
        terminated = true
        isRunning = false
        isBusy = false
        onProcessExit?()
    }
}
