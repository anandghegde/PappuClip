import PappuSelection
import Testing

/// The one clipboard value that lives in a `DetectionPolicy`, and it lives there because of the last
/// test in this suite: a merge of two policies can only ever take away (SEC-9).
@Suite struct CopyDeltaTests {
    @Test func acceptsOnlyWhatIsInRange() {
        #expect(CopyDelta.one.contains(1))
        #expect(!CopyDelta.one.contains(0))
        #expect(!CopyDelta.one.contains(2))
        #expect(CopyDelta.oneOrTwo.contains(2))
    }

    /// An empty range accepts nothing at all, including the delta a copy would actually produce. It is
    /// how a policy says "never simulate ⌘C here", and `syntheticCopyPermit` reads it that way.
    @Test func anEmptyRangeAcceptsNothing() {
        #expect(CopyDelta.none.isEmpty)
        for delta in -1...3 {
            #expect(!CopyDelta.none.contains(delta))
        }
    }

    /// Two ways of saying "no" have to be one value, or a policy that forbids synthetic copy would not
    /// compare equal to another that forbids it differently.
    @Test(arguments: [(5, 2), (1, 0), (0, -1)])
    func everySpellingOfEmptyIsTheSameValue(minimum: Int, maximum: Int) {
        #expect(CopyDelta(minimum: minimum, maximum: maximum) == .none)
    }

    @Test func intersectionNarrows() {
        #expect(CopyDelta.one.intersected(with: .oneOrTwo) == .one)
        #expect(CopyDelta.oneOrTwo.intersected(with: CopyDelta(minimum: 2, maximum: 3)) == CopyDelta(minimum: 2, maximum: 2))
        #expect(CopyDelta.one.intersected(with: CopyDelta(minimum: 2, maximum: 3)).isEmpty)
        #expect(CopyDelta.oneOrTwo.intersected(with: .none) == .none)
    }

    /// The property `DetectionPolicy.restricted(by:)` relies on, over every pair of a small set: an
    /// intersection is at least as restrictive as both sides, and it never accepts a delta neither of
    /// them did.
    @Test func anIntersectionCanOnlyTakeAway() {
        let ranges: [CopyDelta] = [
            .one, .oneOrTwo, .none,
            CopyDelta(minimum: 2, maximum: 3),
            CopyDelta(minimum: 0, maximum: 4),
        ]
        for left in ranges {
            for right in ranges {
                let merged = left.intersected(with: right)
                #expect(merged.isAtLeastAsRestrictive(as: left))
                #expect(merged.isAtLeastAsRestrictive(as: right))
                for delta in -1...5 {
                    #expect(merged.contains(delta) == (left.contains(delta) && right.contains(delta)))
                }
            }
        }
    }
}
