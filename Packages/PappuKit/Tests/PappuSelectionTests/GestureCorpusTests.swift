import CoreGraphics
import Foundation
import PappuDevTools
import PappuSelection
import PappuTestSupport
import Testing

/// Replays every recording under `Tests/gestures/` (architecture §17).
@Suite struct GestureCorpusTests {
    static let directory = "Tests/gestures"

    static func recordings() throws -> [(file: String, recording: GestureRecording)] {
        let root = try RepositoryRoot.find(from: URL(filePath: #filePath)).appending(path: directory)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.flatMap { file in
            try JSONDecoder().decode([GestureRecording].self, from: Data(contentsOf: file))
                .map { (file.lastPathComponent, $0) }
        }
    }

    @Test func everyRecordingReplaysToItsExpectedGestures() throws {
        let recordings = try Self.recordings()
        #expect(!recordings.isEmpty)
        for (file, recording) in recordings {
            let replayed = recording.replay().map(\.gesture)
            #expect(replayed == recording.expected, "\(file): \(recording.name)")
        }
    }

    /// PRD §3.3 measures false positives against non-trigger interactions, so the corpus must hold some.
    @Test func theCorpusHoldsTriggerAndNonTriggerInteractions() throws {
        let recordings = try Self.recordings().map(\.recording)
        #expect(recordings.contains { $0.expected.isEmpty })
        #expect(recordings.contains { !$0.expected.isEmpty })
    }

    @Test func aRecordingSurvivesARoundTrip() throws {
        let recording = GestureRecording(
            name: "round trip",
            events: [
                PointerEvent(kind: .down, location: CGPoint(x: 1.5, y: 2), modifiers: [.shift, .command], timestampNs: 3, windowNumber: 4),
            ],
            expected: [.multiClick(count: 3, dragged: true), .shiftClick, .dragSelect(direction: .upwards)]
        )
        let decoded = try JSONDecoder().decode(GestureRecording.self, from: JSONEncoder().encode(recording))
        #expect(decoded == recording)
    }

    @Test func anUnknownModifierIsAnErrorNotAnEmptySet() {
        let json = Data(#"{"kind":"down","location":[0,0],"modifiers":["hyper"],"clickCount":1,"timestampNs":0,"windowNumber":1}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PointerEvent.self, from: json) }
    }
}
