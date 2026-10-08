import EventKit
import Foundation

/// Announces calendar events shortly before they start. Asks for calendar access the first time a wallpaper
/// on screen reacts to meetings.
@MainActor
final class CalendarWatch {
    var onMeeting: (() -> Void)?
    var lead: TimeInterval = 120
    private let store = EKEventStore()
    private var timer: Timer?
    private var announced: Set<String> = []
    private var asked = false

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 5
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined:
            guard !asked else { return }
            asked = true
            store.requestFullAccessToEvents { [weak self] granted, _ in
                guard granted else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.check() } }
            }
            return
        default: return
        }
        let now = Date()
        let soon = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(lead), calendars: nil))
        let due = soon.filter { e in
            !e.isAllDay && e.startDate > now && e.status != .canceled
                && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
        }
        let fresh = due.filter { announced.insert("\($0.calendarItemIdentifier)@\($0.startDate.timeIntervalSince1970)").inserted }
        if !fresh.isEmpty { onMeeting?() }
    }
}
