import SwiftUI
import EventKit
import ProjKitCore

/// Apple Reminders through EventKit: reminders for tasks go into the "Projects Tasks" list
/// (created on first use). The CLI and web UI do the same through the Reminders app
/// (src/projkit/reminders.py, same list name and notes). The task records the time with
/// `Ops.setTaskReminder` ("<!-- reminder:YYYY-MM-DDTHH:MM -->").
@MainActor
enum Reminders {
    static let listName = "Projects Tasks"
    private static let store = EKEventStore()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// The local "YYYY-MM-DDTHH:MM" form recorded in the task.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date)
    }

    static func date(_ stamp: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: stamp)
    }

    /// "Nov 10, 2026 at 9:00 AM" in the user's locale (falls back to the stored text).
    static func label(_ stamp: String) -> String {
        date(stamp)?.formatted(date: .abbreviated, time: .shortened) ?? stamp
    }

    /// Tomorrow at 9:00, the default time offered.
    static var defaultDate: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private static func list() throws -> EKCalendar {
        if let c = store.calendars(for: .reminder).first(where: { $0.title == listName }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = listName
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw Failure("No Reminders account to create the “\(listName)” list in.")
        }
        c.source = source
        try store.saveCalendar(c, commit: true)
        return c
    }

    /// Asks for access (first time only), then creates the reminder with an alarm at `date`.
    static func create(title: String, date: Date, notes: String) async throws {
        let granted: Bool
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: granted = true
        case .notDetermined: granted = try await store.requestFullAccessToReminders()
        default: granted = false
        }
        guard granted else {
            throw Failure("Proj isn’t allowed to use Reminders. Turn it on in Settings › Privacy & Security › Reminders.")
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        r.calendar = try list()
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        r.addAlarm(EKAlarm(absoluteDate: date))
        try store.save(r, commit: true)
    }
}

/// Schedules an Apple Reminder for a task: text (default the task's text, editable) and date & time.
struct ReminderSheet: View {
    let task: ProjectTask
    let project: Project
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Reminders.defaultDate
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Reminder", text: $text, axis: .vertical)
                    DatePicker("Remind me", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    if let problem { Text(problem).foregroundStyle(.red) }
                } footer: {
                    if let when = task.reminder {
                        Text("A reminder was already scheduled for \(Reminders.label(when)). This adds another one in the “\(Reminders.listName)” list.")
                    } else {
                        Text("Goes into the “\(Reminders.listName)” list in Reminders.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Reminder")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheetSize(width: 460, height: 340)
        .onAppear {
            text = task.text
            if let when = task.reminder.flatMap(Reminders.date), when > Date() { date = when }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let title = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        do {
            try await Reminders.create(title: title, date: date, notes: "Project: \(project.title)")
        } catch {
            problem = error.localizedDescription
            return
        }
        let stamp = Reminders.stamp(date), index = task.index, p = project
        await model.perform { try Ops.setTaskReminder($0, p, index: index, when: stamp) }
        dismiss()
    }
}
