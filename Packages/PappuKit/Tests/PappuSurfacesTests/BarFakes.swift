import CoreGraphics
import Foundation
import PappuCore
import PappuSelection
import PappuSurfaces
import Synchronization

// MARK: The pieces a bar is made of, said plainly

let target = TargetApp(pid: 501, bundleID: "com.apple.Safari")

func item(_ id: String, _ name: String? = nil, enabled: Bool = true, why: String? = nil) -> BarItem {
    BarItem(
        id: BarItemID(id),
        name: name ?? id.capitalized,
        display: .icon(.symbol("doc.on.doc")),
        isEnabled: enabled,
        disabledExplanation: why
    )
}

func content(_ ids: String...) -> BarContent {
    BarContent(items: ids.map { item($0) })
}

func presentation(
    bounds: CGRect? = nil,
    pointer: CGPoint? = nil,
    drag: DragDirection? = nil,
    route: ActivationRoute = .automatic
) -> AttemptPresentation {
    AttemptPresentation(
        attempt: AttemptID(rawValue: 1),
        route: route,
        target: target,
        verdict: .selection,
        text: "some words",
        bounds: bounds,
        pointer: pointer,
        dragDirection: drag
    )
}

func grant(
    _ attempt: UInt64 = 1,
    route: ActivationRoute = .automatic,
    remaining: Duration = .milliseconds(400)
) -> BarGrant {
    BarGrant(attempt: AttemptID(rawValue: attempt), route: route, target: target, remaining: remaining)
}

func key(_ code: UInt16, _ modifiers: PointerEvent.Modifiers = [], repeating: Bool = false) -> KeyPress {
    KeyPress(keyCode: code, modifiers: modifiers, isRepeat: repeating, timestampNs: 0)
}

enum Keys {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let enter: UInt16 = 36
    static let escape: UInt16 = 53
    static let letterA: UInt16 = 0
}

func mouse(_ kind: PointerEvent.Kind, at location: CGPoint) -> PointerEvent {
    PointerEvent(kind: kind, location: location, timestampNs: 0, windowNumber: 0)
}

/// One 1440 × 900 display with a 25 pt menu bar, in this module's top-left coordinates.
let mainScreen = BarScreen(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875)
)

/// A second display to the right, which is where a bar has to follow a selection (BAR-2).
let rightScreen = BarScreen(
    id: 2,
    frame: CGRect(x: 1440, y: 0, width: 1000, height: 600),
    visibleFrame: CGRect(x: 1440, y: 0, width: 1000, height: 600)
)

// MARK: Seams

/// The window, as a list of what it was told to do.
@MainActor
final class RecordingWindow: BarWindowing {
    enum Call: Equatable {
        case prepared
        case shown(items: [String], frame: CGRect, background: BarBackgroundStyle)
        case highlighted(Int?)
        case presented(BarFeedbackState, BarMotion)
        case announced(String)
        case hidden
    }

    weak var events: (any BarWindowEvents)?
    private(set) var calls: [Call] = []
    private(set) var isVisible = false
    private(set) var frame: CGRect = .null
    private(set) var lastPlacement: BarPlacement?

    func prepare() { calls.append(.prepared) }

    func show(_ content: BarContent, placement: BarPlacement, appearance: BarAppearance, metrics: BarMetrics) {
        isVisible = true
        frame = placement.windowFrame(metrics: metrics)
        lastPlacement = placement
        calls.append(.shown(
            items: content.items.map(\.id.rawValue),
            frame: placement.frame,
            background: appearance.background
        ))
    }

    func highlight(_ index: Int?) { calls.append(.highlighted(index)) }
    func present(_ feedback: BarFeedbackState, motion: BarMotion) { calls.append(.presented(feedback, motion)) }
    func announce(_ message: String) { calls.append(.announced(message)) }

    func hide() {
        isVisible = false
        frame = .null
        calls.append(.hidden)
    }

    var announcements: [String] {
        calls.compactMap { if case .announced(let message) = $0 { message } else { nil } }
    }

    var highlights: [Int?] {
        calls.compactMap { if case .highlighted(let index) = $0 { index } else { nil } }
    }

    func press(_ id: String, modifiers: PointerEvent.Modifiers = []) {
        events?.barPressed(BarItemID(id), modifiers: modifiers)
    }
}

/// What the resolver will return in M1 week 5.
struct FixedContent: BarContentProviding {
    var fixed: BarContent
    func content(for presentation: AttemptPresentation) async -> BarContent { fixed }
}

/// What the invoker was asked to do, and what it was asked to stop.
final class RecordingInvoker: BarActionInvoking {
    private struct State {
        var clicks: [BarClick] = []
        var cancellations = 0
    }

    private let state = Mutex(State())

    var clicks: [BarClick] { state.withLock(\.clicks) }
    var cancellations: Int { state.withLock(\.cancellations) }

    func invoke(_ click: BarClick, for presentation: AttemptPresentation) async {
        state.withLock { $0.clicks.append(click) }
    }

    func cancelRunningAction() async {
        state.withLock { $0.cancellations += 1 }
    }
}

struct FixedScreens: BarScreenSource {
    var all: [BarScreen] = [mainScreen]
    func screens() -> [BarScreen] { all }
}

struct FixedAppearance: SystemAppearanceReading {
    var settings = SystemAppearanceSettings()
    func currentAppearance() -> SystemAppearanceSettings { settings }
}

/// Every button the same width, so that a placement test says what it means.
struct FixedWidths: BarMeasuring {
    var each: CGFloat = 30
    func widths(for content: BarContent, metrics: BarMetrics) -> [CGFloat] {
        Array(repeating: each, count: content.count)
    }
}

/// The key tap, as a handler a test can press keys into (ACT-19).
final class RecordingKeys: BarKeyLeasing {
    private struct State {
        var handler: (@Sendable (KeyPress) -> TapDisposition)?
        var leases = 0
        var stops = 0
    }

    private let state = Mutex(State())
    private let refuses: Bool

    /// `refuses: true` is macOS turning the tap down, which is what a missing Accessibility grant
    /// looks like from here.
    init(refuses: Bool = false) {
        self.refuses = refuses
    }

    var leases: Int { state.withLock(\.leases) }
    var stops: Int { state.withLock(\.stops) }
    var isHeld: Bool { state.withLock { $0.handler != nil } }

    func leaseKeys(_ handler: @escaping @Sendable (KeyPress) -> TapDisposition) -> (any InputWatch)? {
        guard !refuses else { return nil }
        state.withLock {
            $0.leases += 1
            $0.handler = handler
        }
        return Lease(owner: self)
    }

    @discardableResult
    func press(_ press: KeyPress) -> TapDisposition {
        guard let handler = state.withLock(\.handler) else { return .pass }
        return handler(press)
    }

    fileprivate func release() {
        state.withLock {
            guard $0.handler != nil else { return }
            $0.handler = nil
            $0.stops += 1
        }
    }

    private final class Lease: InputWatch {
        private let owner: RecordingKeys
        init(owner: RecordingKeys) { self.owner = owner }
        func stop() { owner.release() }
    }
}

// MARK: Assembly

@MainActor
struct Bar {
    let window = RecordingWindow()
    let invoker = RecordingInvoker()
    let keys: RecordingKeys
    let controller: BarController

    init(
        content: BarContent = content("copy", "search", "define"),
        screens: [BarScreen] = [mainScreen],
        appearance: SystemAppearanceSettings = SystemAppearanceSettings(),
        settings: BarSettings = BarSettings(),
        keys: RecordingKeys = RecordingKeys()
    ) {
        self.keys = keys
        controller = BarController(
            window: window,
            content: FixedContent(fixed: content),
            invoker: invoker,
            screens: FixedScreens(all: screens),
            appearance: FixedAppearance(settings: appearance),
            measurer: FixedWidths(),
            keys: keys,
            settings: settings
        )
    }

    @discardableResult
    func show(_ presentation: AttemptPresentation = presentation(bounds: CGRect(x: 600, y: 400, width: 200, height: 20)),
              grant: BarGrant = grant()) async -> BarController {
        await controller.show(presentation, grant: grant)
        return controller
    }
}
