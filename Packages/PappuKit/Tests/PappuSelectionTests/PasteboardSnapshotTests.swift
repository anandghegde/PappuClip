import Foundation
import PappuSelection
import PappuTestSupport
import Testing

private let ceiling = ClipboardTiming.initial.ceilingBytes

private func representation(_ type: String, _ text: String) -> PasteboardRepresentation {
    PasteboardRepresentation(type: type, data: Data(text.utf8))
}

/// ACT-10a: the user's clipboard comes back the way it went in, or the transaction never starts.
@Suite struct PasteboardSnapshotTests {
    @Test func keepsEveryItemAndTypeInOrder() throws {
        let items = [
            [representation("public.utf8-plain-text", "one"), representation("public.html", "<p>one</p>")],
            [representation("public.utf8-plain-text", "two")],
        ]
        let pasteboard = ScriptedPasteboard(text: nil)
        pasteboard.put(items)

        let snapshot = try PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling).get()

        #expect(snapshot.items == items)
        #expect(snapshot.representationCount == 3)
        #expect(snapshot.bytes == items.flatMap { $0 }.reduce(0) { $0 + $1.data.count })
    }

    /// A type this build has never heard of is carried through byte for byte: the snapshot is not
    /// allowed to understand the clipboard in order to put it back.
    @Test func carriesTypesItDoesNotKnow() throws {
        let odd = [[representation("com.example.some-private-format", "\u{0}\u{1}opaque")]]
        let pasteboard = ScriptedPasteboard(text: nil)
        pasteboard.put(odd)

        let snapshot = try PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling).get()
        _ = snapshot.restore(to: pasteboard, expecting: snapshot.changeCount)

        #expect(pasteboard.currentTypes == [["com.example.some-private-format"] + PasteboardMarker.all])
        let written = try #require(pasteboard.brokerWrites.last)
        #expect(written[0][0] == odd[0][0])
    }

    @Test func refusesAFilePromise() {
        let pasteboard = ScriptedPasteboard(text: nil)
        pasteboard.put([[representation("com.apple.pasteboard.promised-file-content-type", "")]])

        #expect(PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling) == .failure(.filePromise))
    }

    /// M0 spike 6 saw this for a promise whose owner had died: the type is listed and the bytes are not
    /// there. It is as unrestorable as a promise and refused the same way.
    @Test func refusesARepresentationThatHandsBackNothing() {
        let pasteboard = ScriptedPasteboard(text: nil)
        pasteboard.put([[representation("public.tiff", "pixels")]], unreadable: ["public.tiff"])

        #expect(PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling) == .failure(.unreadableRepresentation))
    }

    @Test func refusesWhatIsOverTheCeiling() {
        let pasteboard = ScriptedPasteboard(text: nil)
        pasteboard.put([[PasteboardRepresentation(type: "public.data", data: Data(count: 1_024))]])

        #expect(PasteboardSnapshot.take(from: pasteboard, ceilingBytes: 512) == .failure(.tooLarge))
    }

    /// Asked before the pasteboard is read, so finding out costs nothing and raises no prompt
    /// (architecture §19 item 3).
    @Test(arguments: [PasteboardAccess.ask, .alwaysDeny])
    func refusesWhenAReadWouldPromptOrFail(access: PasteboardAccess) {
        let pasteboard = ScriptedPasteboard()
        pasteboard.set(access: access)

        #expect(PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling) == .failure(.accessNotAllowed))
    }

    @Test(arguments: [PasteboardAccess.alwaysAllow, .systemDefault])
    func readsWhenItMay(access: PasteboardAccess) throws {
        let pasteboard = ScriptedPasteboard()
        pasteboard.set(access: access)

        #expect(throws: Never.self) { try PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling).get() }
    }

    /// ACT-10h. Without the markers every clipboard fallback would leave a duplicate entry in every
    /// clipboard manager on the Mac.
    @Test func asksClipboardManagersToIgnoreTheRestore() throws {
        let pasteboard = ScriptedPasteboard(text: "held")
        let snapshot = try PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling).get()

        for item in snapshot.markedItems() {
            #expect(PasteboardMarker.all.allSatisfy { marker in item.contains { $0.type == marker } })
        }
        // And only once, for a clipboard whose owner had already asked managers to ignore it — a
        // password manager's copy, which is where the markers came from in the first place.
        let already = ScriptedPasteboard(text: nil)
        already.put([[
            representation(ScriptedPasteboard.textType, "a generated password"),
            representation(PasteboardMarker.concealed, ""),
        ]])
        let marked = try PasteboardSnapshot.take(from: already, ceilingBytes: ceiling).get().markedItems()
        #expect(marked[0].filter { $0.type == PasteboardMarker.concealed }.count == 1)
        #expect(marked[0].count == 3)
    }

    /// An empty clipboard is put back as an empty clipboard. Writing nothing after the clear would
    /// leave the count moved and somebody else's content still readable.
    @Test func putsAnEmptyClipboardBackAsEmpty() throws {
        let pasteboard = ScriptedPasteboard(text: nil)
        let snapshot = try PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling).get()
        #expect(snapshot.isEmpty)

        pasteboard.put([[representation("public.utf8-plain-text", "somebody else's")]])
        _ = snapshot.restore(to: pasteboard, expecting: pasteboard.changeCount)

        #expect(pasteboard.currentText == nil)
        #expect(pasteboard.brokerWrites.isEmpty)
    }

    /// ACT-10f. The gap between the count check and `clearContents()` cannot be closed — spike 6
    /// measured it at 0.13 ms idle — so the only thing that can be done is to know it happened.
    @Test func noticesAWriteItDestroyedInTheGap() throws {
        let pasteboard = ScriptedPasteboard(text: "held")
        let snapshot = try PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling).get()

        let quiet = snapshot.restore(to: pasteboard, expecting: pasteboard.changeCount)
        #expect(!quiet.destroyedANewerWrite)
        #expect(quiet.cleared == snapshot.changeCount + 1)

        let checked = pasteboard.changeCount
        pasteboard.writeInRestoreGap("newer than us")
        let contended = snapshot.restore(to: pasteboard, expecting: checked)
        #expect(contended.destroyedANewerWrite)
    }
}
