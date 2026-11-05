import Foundation

/// Tells the host which navigation callbacks belong to its own page load: those of a navigation `WKWebView.load`
/// returned for it. Another document can commit after `load(url:)` began, from a navigation the previous document
/// started, and its navigation can even cancel the page's, with no callback for the page at all.
/// - Such a commit before the page's load is issued changes nothing: the load still comes.
/// - After the issue, the page is issued again, once per host load; a second such commit fails the load.
///
/// Pure and main-thread only, like the navigation delegate that drives it. Navigations are compared by identity.
final class HostLoadTracker {
    enum Commit: Equatable { case page, other, otherReissue, otherFailLoad }
    enum Finish: Equatable { case probe, ignore }
    enum Failure: Equatable { case hostLoad, page, ignore }

    private enum State { case idle, awaitingIssue, awaitingPage }

    private var state = State.idle
    // The navigation of the page's latest issue, and those of the issues before it. An earlier issue that commits
    // after the reissue was sent does not cancel the reissue, which commits later and replaces it.
    private var latestIssue: AnyObject?
    private var earlierIssues: [AnyObject] = []
    private var reissued = false

    /// A host load began; its page is not issued yet.
    func load() {
        state = .awaitingIssue
        latestIssue = nil
        earlierIssues = []
        reissued = false
    }

    /// The host issued the page's load, which `WKWebView.load` answered with `navigation`.
    func issued(_ navigation: AnyObject?) {
        if let previous = latestIssue { earlierIssues.append(previous) }
        latestIssue = navigation
        state = .awaitingPage
    }

    /// A main-frame navigation committed (`didCommit`).
    func committed(_ navigation: AnyObject?) -> Commit {
        switch state {
        case .idle, .awaitingIssue:
            return .other
        case .awaitingPage:
            if isLatestIssue(navigation) {
                state = .idle
                return .page
            }
            if isEarlierIssue(navigation) { return .other }
            if reissued {
                state = .idle
                return .otherFailLoad
            }
            reissued = true
            return .otherReissue
        }
    }

    /// A main-frame page-finish (`didFinish`): only the page's own document is probed.
    func finished() -> Finish { state == .idle ? .probe : .ignore }

    /// A navigation failed genuinely (`didFailProvisionalNavigation` / `didFail`): whose it is. The page's own load
    /// failing ends the wait, so nothing is issued for a payment that already failed.
    func failed(_ navigation: AnyObject?) -> Failure {
        switch state {
        case .idle: return .page
        case .awaitingIssue: return .ignore
        case .awaitingPage:
            guard isLatestIssue(navigation) else { return .ignore }
            state = .idle
            return .hostLoad
        }
    }

    private func isLatestIssue(_ navigation: AnyObject?) -> Bool {
        guard let navigation, let latestIssue else { return false }
        return navigation === latestIssue
    }

    private func isEarlierIssue(_ navigation: AnyObject?) -> Bool {
        guard let navigation else { return false }
        return earlierIssues.contains { $0 === navigation }
    }
}
