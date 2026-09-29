import Foundation
import PappuDiagnostics
import PappuJSBridge
@testable import PappuRuntime
import Testing

/// DEV-1: the client sends debugging only for the owners it was told are development folders, and a
/// change reaches a world that is already loaded.
@Suite struct JSHostDebuggingTests {
    private func development(_ setup: JSHostClientTests.Setup) -> [String] {
        setup.console.entries.filter { $0.kind == .printed && $0.text.hasPrefix("[development] ") }.map(\.source)
    }

    @Test func onlyADevelopmentOwnerIsVerbose() async throws {
        let setup = try JSHostClientTests.Setup()
        setup.client.setDebugging(["ext-dev": JSDebug(verbose: true)])
        _ = await setup.run(setup.job("return 'a'"))
        _ = await setup.run(setup.job("return 'd'", owner: "ext-dev", name: "Dev"))
        let sources = development(setup)
        #expect(!sources.isEmpty)
        #expect(Set(sources) == ["Dev"])
        #expect(setup.client.debugging(for: "ext-dev") == JSDebug(verbose: true))
        #expect(setup.client.debugging(for: "ext-a") == nil)
    }

    @Test func changingTheSettingReloadsALoadedWorld() async throws {
        let setup = try JSHostClientTests.Setup()
        _ = await setup.run(setup.job("return 'a'"))
        #expect(setup.transport.current?.loads == 1)
        #expect(development(setup).isEmpty)

        setup.client.setDebugging(["ext-a": JSDebug(verbose: true)])
        _ = await setup.run(setup.job("return 'a'"))
        #expect(setup.transport.current?.loads == 2)
        #expect(!development(setup).isEmpty)

        // The same setting again changes nothing, and nothing is reloaded.
        setup.client.setDebugging(["ext-a": JSDebug(verbose: true)])
        _ = await setup.run(setup.job("return 'a'"))
        #expect(setup.transport.current?.loads == 2)

        // Turned off, it is reloaded without.
        setup.client.setDebugging([:])
        let before = development(setup).count
        _ = await setup.run(setup.job("return 'a'"))
        #expect(setup.transport.current?.loads == 3)
        #expect(development(setup).count == before)
    }

    @Test func anEmptySettingIsNoSetting() throws {
        let setup = try JSHostClientTests.Setup()
        setup.client.setDebugging(["ext-a": JSDebug()])
        #expect(setup.client.debugging(for: "ext-a") == nil)
    }
}
