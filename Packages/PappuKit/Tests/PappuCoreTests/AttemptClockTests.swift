import PappuCore
import PappuTestSupport
import Testing

@Suite struct AttemptClockTests {
    @Test func elapsedFollowsTheInjectedTimeSource() {
        let time = ManualTimeSource()
        let clock = AttemptClock(now: time.reader)
        #expect(clock.elapsed == .zero)
        time.advance(by: .milliseconds(42))
        #expect(clock.elapsed == .milliseconds(42))
    }

    @Test func remainingCountsDownAndClampsAtZero() {
        let time = ManualTimeSource()
        let clock = AttemptClock(now: time.reader)
        time.advance(by: .milliseconds(50))
        #expect(clock.remaining(in: .stage(.read), on: .accessibility) == .milliseconds(20))
        #expect(clock.remaining(in: .targetBudget, on: .accessibility) == .milliseconds(100))
        time.advance(by: .milliseconds(500))
        #expect(clock.remaining(in: .stage(.read), on: .accessibility) == .zero)
        #expect(clock.remaining(in: .targetBudget, on: .clipboardFallback) == .zero)
    }

    /// PRD §11.1: the fallback path's budget includes the time the Accessibility strategies spent.
    @Test func fallbackInheritsTimeSpentOnEarlierStrategies() {
        let time = ManualTimeSource()
        let clock = AttemptClock(now: time.reader)
        time.advance(by: .milliseconds(70))
        #expect(clock.remaining(in: .stage(.read), on: .accessibility) == .zero)
        #expect(clock.remaining(in: .stage(.read), on: .clipboardFallback) == .milliseconds(200))
    }

    @Test func startCanBeBackdatedToTheEventTime() {
        let time = ManualTimeSource()
        let eventTime = time.now
        time.advance(by: .milliseconds(8))
        let clock = AttemptClock(start: eventTime, now: time.reader)
        #expect(clock.elapsed == .milliseconds(8))
    }

    @Test func targetBudgetAndHardCutoffAreSeparateThresholds() {
        let time = ManualTimeSource()
        let clock = AttemptClock(now: time.reader)
        time.advance(by: .milliseconds(150))
        #expect(clock.isPastTargetBudget(on: .accessibility))
        #expect(!clock.isPastTargetBudget(on: .clipboardFallback))
        #expect(!clock.isPastHardCutoff)
        time.advance(by: .milliseconds(550))
        #expect(clock.isPastHardCutoff)
    }
}
