import AppKit
import Contacts
import EventKit

// Requests that carry details: reminders, calendar events, emails.
// A rule-based reading shows instantly; the language model then refines it in place.
enum Commands {
    static let store = EKEventStore()

    static let whenFmt: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // Only infer AM/PM for a time with no explicit date or meridiem.
    static func nextDetectedTime(_ date: Date, matched: String, now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard date < now, calendar.isDate(date, inSameDayAs: now),
              let time = Calc.rx(matched.trimmingCharacters(in: .whitespaces), "^(?:at\\s+)?\\d{1,2}(?::\\d{2})?\\s*(a\\.?m\\.?|p\\.?m\\.?)?$") else { return date }
        if time[1].isEmpty, calendar.component(.hour, from: date) < 12,
           let evening = calendar.date(byAdding: .hour, value: 12, to: date), evening > now { return evening }
        return calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    // "tomorrow at 5pm", "in 2 hours", "friday 1pm" -> date, and the text with that phrase removed
    static func when(_ text: String) -> (Date, String)? {
        if let m = Calc.rx(text, "^(.*?)\\b(?:in|after)\\s+(\\d+|an?|half an)\\s*(min(?:ute)?s?|h(?:ou)?rs?|days?|weeks?)\\b(.*)$") {
            let n = Double(m[2]) ?? (m[2].lowercased() == "half an" ? 0.5 : 1)
            let unit: Double = m[3].lowercased().hasPrefix("m") ? 60 : (m[3].lowercased().hasPrefix("h") ? 3600 : (m[3].lowercased().hasPrefix("d") ? 86400 : 604800))
            return (Date().addingTimeInterval(n * unit), (m[1] + m[4]).trimmingCharacters(in: .whitespaces))
        }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), var d = m.date, let r = Range(m.range, in: text) else {
            // "at 5", "at 7:30": the detector wants am/pm; take the next time the clock shows that hour
            // (an unmarked 1-6 is read as the afternoon)
            guard let m = Calc.rx(text, "^(.*?)\\bat\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b(.*)$"), let h = Int(m[2]), h <= 23 else { return nil }
            let cal = Calendar.current, now = Date()
            let minute = Int(m[3]) ?? 0
            let hours = m[4].lowercased() == "pm" ? [h % 12 + 12] : (m[4].lowercased() == "am" ? [h % 12] : (h >= 1 && h <= 6 ? [h + 12] : (h <= 12 ? [h % 12, h % 12 + 12] : [h])))
            var options: [Date] = []
            for day in 0...1 {
                for hour in hours {
                    if let base = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now)),
                       let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: base), d > now { options.append(d) }
                }
            }
            guard let d = options.min() else { return nil }
            return (d, (m[1] + m[5]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces))
        }
        d = nextDetectedTime(d, matched: String(text[r]))
        var rest = text
        rest.removeSubrange(r)
        rest = rest.replacingOccurrences(of: "\\s+(at|on|by|for|this|next)\\s*$", with: "", options: .regularExpression)
        return (d, rest.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces))
    }

    static func tidy(_ s: String) -> String {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    static func str(_ j: [String: Any]?, _ k: String) -> String? { (j?[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    // a field from the model is used only if its words actually occur in what the user typed
    static func grounded(_ j: [String: Any]?, _ k: String, in text: String) -> String? {
        guard let v = str(j, k) else { return nil }
        let have = Set(nameTokens(text)), want = nameTokens(v).filter { $0.count > 2 }
        guard !want.isEmpty else { return nil }
        let found = want.filter { w in have.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }.count
        return Double(found) / Double(want.count) >= 0.6 ? v : nil
    }

    // MARK: reminder

    static func reminder(_ text: String, _ j: [String: Any]? = nil) -> Hit {
        var body = text.replacingOccurrences(of: "^(please )?(remind me|set a reminder|add a reminder|reminder|remember|todo|to-do)( to| that| about| for|:)?\\s+",
                                             with: "", options: [.regularExpression, .caseInsensitive])
        var due: Date?
        if let (d, rest) = when(body) { due = d; body = rest } else if let w = grounded(j, "when", in: text), let (d, _) = when(w) { due = d }
        body = body.replacingOccurrences(of: "^to\\s+", with: "", options: .regularExpression)
        let title = tidy(grounded(j, "title", in: text) ?? body)
        let sub = (due.map { whenFmt.string(from: $0) } ?? "No due date") + " · Reminders"
        return Hit(title: "Remind me: \(title)", subtitle: sub, icon: .symbol("checklist"), tag: "Reminder", key: "intent:reminder") { _ in
            store.requestFullAccessToReminders { ok, _ in
                DispatchQueue.main.async {
                    guard ok, let cal = store.defaultCalendarForNewReminders() else { return Toast.show("✗ SemBar needs access to Reminders", seconds: 4) }
                    let r = EKReminder(eventStore: store)
                    r.title = title
                    r.calendar = cal
                    if let due {
                        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                        r.addAlarm(EKAlarm(absoluteDate: due))
                    }
                    do {
                        try store.save(r, commit: true)
                        Toast.show("✓ Reminder added" + (due.map { " · " + whenFmt.string(from: $0) } ?? ""))
                    } catch { Toast.show("✗ " + error.localizedDescription, seconds: 4) }
                }
            }
        }
    }

    // MARK: event

    static func event(_ text: String, _ j: [String: Any]? = nil) -> Hit {
        var body = text.replacingOccurrences(of: "^(please )?(schedule|add|create|new|put|book|set up)( an?| a new)?( calendar)?( event| meeting| appointment)?( for| called|:)?\\s+",
                                             with: "", options: [.regularExpression, .caseInsensitive])
        var start: Date?
        if let (d, rest) = when(body) { start = d; body = rest } else if let w = grounded(j, "when", in: text), let (d, _) = when(w) { start = d }
        var location = grounded(j, "location", in: text).map(tidy)
        if let m = Calc.rx(body, "^(.+?)\\s+at\\s+(?!\\d)(.+)$") { (body, location) = (m[1], location ?? tidy(m[2])) }
        let title = tidy(grounded(j, "title", in: text) ?? body)
        let sub = [(start.map { whenFmt.string(from: $0) } ?? "No time found"), location, "Calendar"].compactMap { $0 }.joined(separator: " · ")
        return Hit(title: "New event: \(title)", subtitle: sub, icon: .symbol("calendar.badge.plus"), tag: "Event", key: "intent:event") { _ in
            guard let start else { return Toast.show("✗ Say when, e.g. “friday 1pm”", seconds: 4) }
            store.requestFullAccessToEvents { ok, _ in
                DispatchQueue.main.async {
                    guard ok, let cal = store.defaultCalendarForNewEvents else { return Toast.show("✗ SemBar needs access to Calendar", seconds: 4) }
                    let e = EKEvent(eventStore: store)
                    e.title = title
                    e.calendar = cal
                    e.startDate = start
                    e.endDate = start.addingTimeInterval(3600)
                    e.location = location
                    do {
                        try store.save(e, span: .thisEvent)
                        Toast.show("✓ Event added · " + whenFmt.string(from: start))
                    } catch { Toast.show("✗ " + error.localizedDescription, seconds: 4) }
                }
            }
        }
    }

    // MARK: email

    static func address(for name: String) -> String? {
        if name.contains("@") { return name }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys = [CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let found = try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found?.compactMap { $0.emailAddresses.first?.value as String? }.first
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    static func email(_ text: String, _ j: [String: Any]? = nil, attached: [String] = []) -> Hit {
        // rules first; the model's reading replaces a field only where it found one in the text
        var to: String?, attachPhrase: String?, body = ""
        if let m = Calc.rx(text, "^(?:send|email|mail)\\s+(?:an? (?:email|mail) )?(?:to\\s+)?(\\S+)\\s+(?:the |my |a )?(.+?)(?:\\s+(?:and )?(?:saying|say|tell (?:him|her|them))\\s+(.+))?$") {
            (to, attachPhrase, body) = (m[1], m[2], m[3])
        }
        if let m = Calc.rx(text, "^(?:send|email|mail)\\s+(?:the |my |a )?(.+?)\\s+to\\s+(\\S+)(?:\\s+(?:and )?(?:saying|say|tell (?:him|her|them))\\s+(.+))?$") {
            (attachPhrase, to, body) = (m[1], m[2], m[3])
        }
        // "email to dan", "send it to dan and say …": the attachment is already in the bar
        if let m = Calc.rx(text, "^(?:send|email|mail)\\s+(?:it |this |that |them |these )?to\\s+(\\S+)(?:\\s+(?:and )?(?:saying|say|tell (?:him|her|them))\\s+(.+))?$") {
            (to, attachPhrase, body) = (m[1], nil, m[2])
        }
        if ["this", "it", "that", "these", "them"].contains(attachPhrase ?? "") { attachPhrase = nil }
        to = grounded(j, "to", in: text) ?? to
        attachPhrase = grounded(j, "attach", in: text) ?? attachPhrase
        body = grounded(j, "body", in: text) ?? body
        var subject = grounded(j, "subject", in: text)
        // what to attach: the file in the bar, else the best match for the phrase the user used
        var files = attached
        if files.isEmpty, let phrase = attachPhrase, let f = Engine.shared.bestFile(phrase) { files = [f] }
        let name = to.map(tidy) ?? "…"
        let addr = to.flatMap(address)
        if subject == nil { subject = files.first.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? attachPhrase.map(tidy) }
        let parts = [addr, files.first.map { "📎 " + ($0 as NSString).lastPathComponent }, body.isEmpty ? nil : "“\(body)”"].compactMap { $0 }
        return Hit(title: "Email \(name)" + (subject.map { ": \($0)" } ?? ""), subtitle: parts.isEmpty ? "New message" : parts.joined(separator: " · "),
                   icon: .symbol("envelope"), tag: "Email", key: "intent:email") { _ in
            // nothing is sent: this opens a draft for you to check
            if files.isEmpty || Sys.app("com.apple.mail") == nil {
                var c = URLComponents()
                c.scheme = "mailto"
                c.path = addr ?? ""
                c.queryItems = [URLQueryItem(name: "subject", value: subject ?? ""), URLQueryItem(name: "body", value: body)]
                if let u = c.url { NSWorkspace.shared.open(u) }
                if !files.isEmpty { Toast.show("Attachments need Apple Mail; opened a plain draft", seconds: 4) }
                return
            }
            var s = "tell application \"Mail\"\n set m to make new outgoing message with properties {subject:\(quote(subject ?? "")), content:\(quote(body + "\n\n")), visible:true}\n"
            if let a = addr ?? to { s += " tell m to make new to recipient with properties {address:\(quote(a))}\n" }
            for f in files { s += " tell m to make new attachment with properties {file name:(POSIX file \(quote(f)))} at after last paragraph of content of m\n" }
            s += " activate\nend tell"
            Sys.script(s)
        }
    }

    // nearest phrasing decides which kind of command this is; the model fills in the fields
    static func intent(_ id: String, _ exemplars: [String], _ make: @escaping (String, [String: Any]?) -> Hit) -> Intent {
        Intent(id: id, exemplars: exemplars) { text in
            var h = make(text, nil)
            if LLM.available {
                h.refine = { done in
                    LLM.shared.command(text, file: nil) { j in
                        guard let j, let a = j["action"] as? String, ["reminder", "event", "email"].contains(a) else { return done(nil) }
                        done(make(text, j))
                    }
                }
            }
            return [h]
        }
    }

    static let intents: [Intent] = [
        intent("reminder", ["remind me to call mum at 5", "remind me to submit the lab report tomorrow", "set a reminder to take out the trash",
                            "remind me in 2 hours to check the oven", "don't let me forget to email the professor", "add buy milk to my reminders",
                            "todo finish the essay by friday"]) { reminder($0, $1) },
        intent("event", ["lunch with sam friday 1pm at nobu", "schedule a meeting with the team tomorrow at 10am", "add dentist appointment next tuesday 9am",
                         "create an event for the concert on saturday night", "put study group on my calendar thursday 6pm",
                         "book a call with priya on monday at 3", "dinner with alex saturday 7pm at the thai place",
                         "coffee with jordan next wednesday at 2", "meeting with my advisor tomorrow 4pm"]) { event($0, $1) },
        intent("email", ["email the syllabus to dan", "send john the budget spreadsheet", "email my professor and say i'll be late",
                         "mail the invoice to accounting", "write an email to sarah about dinner", "send this file to mum"]) { email($0, $1) },
    ]
}
