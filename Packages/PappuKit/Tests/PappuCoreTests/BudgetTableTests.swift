import PappuCore
import Testing

@Suite struct BudgetTableTests {
    let table = BudgetTable.initial

    @Test func initialTotalsMatchThePRD() {
        #expect(table.targetBudget(on: .accessibility) == .milliseconds(150))
        #expect(table.targetBudget(on: .clipboardFallback) == .milliseconds(350))
        #expect(table.hardCutoff == .milliseconds(700))
        #expect(table.populationPerFunction == .milliseconds(15))
    }

    @Test func deadlinesAreCumulative() {
        #expect(table.deadline(through: .read, on: .accessibility) == .milliseconds(70))
        #expect(table.deadline(through: .analysis, on: .accessibility) == .milliseconds(90))
        #expect(table.deadline(through: .population, on: .accessibility) == .milliseconds(120))
        #expect(table.deadline(through: .render, on: .accessibility) == .milliseconds(150))
        #expect(table.deadline(through: .read, on: .clipboardFallback) == .milliseconds(270))
    }

    @Test func onlyTheReadStageDiffersBetweenPaths() {
        for stage in BudgetStage.allCases where stage != .read {
            #expect(table.budget(for: stage, on: .accessibility) == table.budget(for: stage, on: .clipboardFallback))
        }
    }

    @Test func perFunctionCeilingFitsInsideThePopulationStage() {
        for path in DetectionPath.allCases {
            #expect(table.populationPerFunction <= table.budget(for: .population, on: path))
        }
    }

    @Test func targetsStayBelowTheHardCutoff() {
        for path in DetectionPath.allCases {
            #expect(table.targetBudget(on: path) < table.hardCutoff)
        }
    }
}
