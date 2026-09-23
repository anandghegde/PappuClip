import Foundation
import PappuAX

/// The page a browser is showing, over Accessibility (FLT-3, architecture §6.2).
///
/// The AX tier only, which is what M1 has: `AXWebArea` answers `AXURL` and usually `AXTitle`, and both
/// are free — no Automation consent, no AppleScript, no per-browser dictionary. The second tier and the
/// capability table that says which browser needs it are M4 (§11.5), and `BrowserPage.source` is
/// already there to tell the two apart when it arrives.
///
/// It looks only where a browser could be. A native app has no web area and walking its window to find
/// that out would cost the read stage a tree walk on every selection on the Mac, so the walk happens
/// only once something has already said this is web content: either the focused element is the web area
/// itself, or it answered `AXEditableAncestor`, which is a question only WebKit and Chromium answer.
@AXActor
public struct BrowserMetadata: Sendable {
    /// A browser window's web area is a handful of groups down. Six is past every browser measured in
    /// spike 2 and short enough that a window full of chrome cannot run away with the stage.
    public nonisolated static let maxDepth = 6
    public nonisolated static let maxNodes = 128

    private let world: any AXWorld

    public init(world: any AXWorld = SystemAXWorld()) {
        self.world = world
    }

    /// - Parameters:
    ///   - focused: The focused element, whose role has already been read.
    ///   - hasEditableAncestor: Whether that element answered `AXEditableAncestor` — a text box inside
    ///     a page, where the page is the window's web area rather than the element itself.
    /// - Returns: Nil when this is not web content, or when the browser said nothing useful about it.
    public func page(
        from focused: AXElement?,
        role: AXRole?,
        hasEditableAncestor: Bool,
        in application: AXElement
    ) -> BrowserPage? {
        var page: BrowserPage?
        if let focused, role?.role == AXRole.webArea {
            page = read(focused)
        } else if hasEditableAncestor, let area = webArea(in: application) {
            page = read(area)
        }
        guard var page else { return nil }

        // A web area often has no title of its own; the window's is the page's, because a browser puts
        // the page title there.
        if page.title?.isEmpty ?? true {
            page.title = windowTitle(in: application)
        }
        return page.isEmpty ? nil : page
    }

    private func read(_ area: AXElement) -> BrowserPage {
        var url: URL?
        if case .success(let value) = world.attribute(.url, of: area) {
            url = value.asURL
        }
        var title: String?
        if case .success(let value) = world.attribute(.title, of: area) {
            title = value.asString
        }
        return BrowserPage(url: url, title: title, source: .accessibility)
    }

    private func windowTitle(in application: AXElement) -> String? {
        guard let window = focusedWindow(in: application),
              case .success(let value) = world.attribute(.title, of: window)
        else { return nil }
        let title = value.asString
        return (title?.isEmpty ?? true) ? nil : title
    }

    private func focusedWindow(in application: AXElement) -> AXElement? {
        guard case .success(let value) = world.attribute(.focusedWindow, of: application) else { return nil }
        return value.asFirstElement
    }

    /// Breadth-first from the focused window, for the same reason `EditMenuProbe` is: the web area is
    /// shallow and the tab strip above it is not.
    private func webArea(in application: AXElement) -> AXElement? {
        guard let window = focusedWindow(in: application) else { return nil }
        var frontier = [window]
        var depth = 0
        var visited = 0

        while !frontier.isEmpty, depth < Self.maxDepth, visited < Self.maxNodes {
            var next: [AXElement] = []
            for element in frontier {
                guard visited < Self.maxNodes else { break }
                visited += 1
                if case .success(let value) = world.attribute(.role, of: element),
                   value.asString == AXRole.webArea {
                    return element
                }
                if case .success(let value) = world.attribute(.children, of: element) {
                    next.append(contentsOf: value.asElements ?? [])
                }
            }
            frontier = next
            depth += 1
        }
        return nil
    }
}
