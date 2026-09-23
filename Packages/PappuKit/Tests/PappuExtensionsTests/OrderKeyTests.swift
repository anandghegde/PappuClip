import Foundation
@testable import PappuExtensions
import Testing

/// SYN-2's list order: keys that can always be split, compared as plain strings.
@Suite struct OrderKeyTests {
    @Test func keysAreValidatedAndNeverEndInZero() {
        #expect(OrderKey("V") != nil)
        #expect(OrderKey("a0") == nil)
        #expect(OrderKey("") == nil)
        #expect(OrderKey("a-b") == nil)
    }

    @Test func aSequenceIsStrictlyIncreasing() {
        let keys = OrderKey.sequence(500, after: nil)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { OrderKey($0.rawValue) != nil })
    }

    @Test func thereIsAlwaysRoomBetweenTwoKeys() {
        var low = OrderKey.after(nil)
        let high = OrderKey.after(low)
        // Insert repeatedly just above the lower bound, and just below the upper one.
        var upper = high
        for _ in 0..<200 {
            let middle = OrderKey.between(low, upper)
            #expect(low < middle && middle < upper)
            #expect(OrderKey(middle.rawValue) != nil)
            upper = middle
        }
        for _ in 0..<200 {
            let middle = OrderKey.between(low, high)
            #expect(low < middle && middle < high)
            low = middle
        }
    }

    @Test func theEndsOfTheListAreOpen() {
        let only = OrderKey.after(nil)
        #expect(OrderKey.between(nil, only) < only)
        #expect(OrderKey.between(only, nil) > only)
    }

    @Test func sqliteOrderIsStringOrder() {
        let keys = ["1", "V", "V1", "Vz", "a", "z", "zz"].compactMap(OrderKey.init)
        #expect(keys.map(\.rawValue) == keys.map(\.rawValue).sorted())
        #expect(keys == keys.sorted())
    }
}
