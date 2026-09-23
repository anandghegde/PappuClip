import PappuCore
import Testing

@Suite struct SequentialIDTests {
    @Test func idsStartAtOneAndOnlyGoUp() {
        let source = IDSource<AttemptID>()
        let first = source.next()
        let second = source.next()
        #expect(first.rawValue == 1)
        #expect(first < second)
        #expect(second.description == "attempt#2")
    }

    @Test func sourcesAreIndependent() {
        let attempts = IDSource<AttemptID>()
        let invocations = IDSource<InvocationID>()
        _ = attempts.next()
        #expect(invocations.next() == InvocationID(rawValue: 1))
    }

    @Test func concurrentCallersNeverShareAnID() async {
        let source = IDSource<InvocationID>()
        let ids = await withTaskGroup(of: [InvocationID].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<500).map { _ in source.next() } }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        #expect(Set(ids).count == 4_000)
        #expect(ids.max() == InvocationID(rawValue: 4_000))
    }
}
