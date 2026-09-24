import Foundation
import PappuDiagnostics
import Testing

@Suite struct DebugConsoleTests {
    @Test func keepsLinesInOrder() {
        let console = DebugConsole()
        console.add(.printed, from: "A", "one")
        console.add(.returned, from: "B", "two")
        #expect(console.entries.map(\.text) == ["one", "two"])
        #expect(console.entries.map(\.source) == ["A", "B"])
        #expect(console.entries.map(\.kind) == [.printed, .returned])
    }

    @Test func dropsTheOldestPastCapacity() {
        let console = DebugConsole(capacity: 3)
        for index in 1...5 { console.add(.printed, from: "A", "\(index)") }
        #expect(console.entries.map(\.text) == ["3", "4", "5"])
        #expect(Set(console.entries.map(\.id)).count == 3)
    }

    @Test func clearEmptiesIt() {
        let console = DebugConsole()
        console.add(.printed, from: "A", "one")
        console.clear()
        #expect(console.entries.isEmpty)
    }

    @Test func watchersHearOfChanges() async {
        let console = DebugConsole()
        var changes = console.changes().makeAsyncIterator()
        console.add(.printed, from: "A", "one")
        #expect(await changes.next() != nil)
    }
}
