import AppKit
import ApplicationServices

// All automation belongs to the app, after the user invokes the visible Ask row.
// No message is submitted. Unknown UI states stop with a manual paste fallback.
enum AssistantHandoff {
    private static var busy = false

    static var controlPermissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
    static func openPrivacySettings(_ anchor: String?) {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        let target = anchor.map { base + "?" + $0 } ?? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        if let url = URL(string: target), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    static func openControlSettings() {
        // The old Accessibility anchor is not a reliable destination on macOS 27.
        openPrivacySettings(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? nil : "Privacy_Accessibility")
    }
    static func openScreenSettings() { openPrivacySettings("Privacy_ScreenCapture") }
    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(e, name as CFString, &value)
        return value
    }
    private static func string(_ e: AXUIElement, _ name: String) -> String { attr(e, name) as? String ?? "" }
    private static func label(_ e: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { string(e, $0) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func walk(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = [], cursor = 0
        while cursor < queue.count && cursor < 1800 {
            let e = queue[cursor]; cursor += 1; result.append(e)
            if let children = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue += children }
        }
        return result
    }
    private static func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
    private static func menu(_ app: AXUIElement, named name: String) -> Bool {
        guard let bar = attr(app, kAXMenuBarAttribute) else { return false }
        let root = unsafeBitCast(bar, to: AXUIElement.self)
        guard let item = walk(root).first(where: { string($0, kAXTitleAttribute) == name && string($0, kAXRoleAttribute) == kAXMenuItemRole }) else { return false }
        return press(item)
    }
    private static func composer(_ nodes: [AXUIElement]) -> AXUIElement? {
        nodes.first { e in
            let role = string(e, kAXRoleAttribute), name = label(e)
            return (role == kAXTextAreaRole || role == kAXTextFieldRole)
                && (name.contains("Ask ChatGPT") || name.contains("Work with ChatGPT") || name.contains("Message ChatGPT"))
        }
    }
    private static func empty(_ field: AXUIElement) -> Bool {
        let value = string(field, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty
    }
    private static func composerScope(_ field: AXUIElement) -> AXUIElement {
        var scope = field
        for _ in 0..<3 {
            guard let parent = attr(scope, kAXParentAttribute) else { break }
            scope = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return scope
    }
    private static func hasDraftAttachments(_ field: AXUIElement) -> Bool {
        walk(composerScope(field)).contains { node in
            let name = label(node).lowercased()
            if ["remove file", "remove attachment", "cancel upload", "uploading"].contains(where: name.contains) { return true }
            // A send action enabled with an empty composer can represent an attachment-only draft.
            return string(node, kAXRoleAttribute) == kAXButtonRole
                && ["send", "send message", "send prompt"].contains(name)
                && (attr(node, kAXEnabledAttribute) as? Bool == true)
        }
    }
    struct AttachmentCard {
        let filename: String
        let ready: Bool
    }
    static func attachmentsVerified(_ files: [String], cards: [AttachmentCard]) -> Bool {
        var available: [String: Int] = [:]
        for card in cards where card.ready { available[card.filename, default: 0] += 1 }
        for file in files {
            let name = (file as NSString).lastPathComponent
            guard available[name, default: 0] > 0 else { return false }
            available[name, default: 0] -= 1
        }
        return true
    }
    private static func attachmentCards(_ field: AXUIElement, files: [String]) -> [AttachmentCard] {
        let names = Set(files.map { ($0 as NSString).lastPathComponent })
        return walk(composerScope(field)).compactMap { node in
            guard string(node, kAXRoleAttribute) == kAXButtonRole else { return nil }
            let title = label(node)
            let direct = names.first { name in ["Remove \(name)", "Remove file \(name)", "Remove attachment \(name)"].contains(title) }
            guard direct != nil || ["Remove file", "Remove attachment"].contains(title) else { return nil }
            guard let parent = attr(node, kAXParentAttribute) else { return nil }
            let cardNodes = walk(unsafeBitCast(parent, to: AXUIElement.self)).filter {
                ![kAXTextAreaRole, kAXTextFieldRole].contains(string($0, kAXRoleAttribute))
            }
            let values = cardNodes.flatMap { [label($0), string($0, kAXValueAttribute)] }
            guard let name = direct ?? names.first(where: { values.contains($0) }) else { return nil }
            let blocked = cardNodes.contains { child in
                let role = string(child, kAXRoleAttribute)
                if role == kAXProgressIndicatorRole { return true }
                return [label(child), string(child, kAXValueAttribute)].contains { value in
                    let v = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    return ["uploading", "uploading…", "uploading...", "cancel upload", "upload failed", "file upload failed", "failed to upload", "retry upload"].contains(v)
                        || v.hasPrefix("upload failed:") || v.hasPrefix("failed to upload:")
                }
            }
            return AttachmentCard(filename: name, ready: !blocked)
        }
    }
    private static func copy(_ question: String, files: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if files.isEmpty { pb.setString(question, forType: .string) }
        else {
            pb.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
            // Older AppKit and Electron builds read this Finder representation.
            pb.setPropertyList(files, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        }
    }
    private static func poll(timeout: TimeInterval, _ check: @escaping () -> Bool, done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func step() {
            if check() { done(true) }
            else if Date() >= deadline { done(false) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: step) }
        }
        step()
    }

    static func start(question: String, files: [String], app url: URL?) {
        guard !busy else {
            AssistantDraft.show(question: question, files: files, destination: url, reason: "Another ChatGPT draft is being prepared. Your request is kept here; retry when it finishes.",
                retry: { edited, remaining in Assistant.ask(edited, files: remaining, app: url != nil, to: .chatgpt) })
            return
        }
        busy = true
        let prompt = question.isEmpty ? "Explain the attached files." : question
        func fallback(_ message: String, settings: (() -> Void)? = nil) {
            copy(prompt, files: files)
            busy = false
            AssistantDraft.show(question: prompt, files: files, destination: url, reason: message,
                retry: { edited, remaining in Assistant.ask(edited, files: remaining, app: url != nil, to: .chatgpt) }, settings: settings)
        }
        guard let url else {
            // A fresh browser page, without auto-submitting a URL query or touching another tab's draft.
            Sys.open("https://chatgpt.com/")
            fallback("ChatGPT opened")
            return
        }
        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: open) { running, error in
            DispatchQueue.main.async {
                guard let running, error == nil else { fallback("Could not open ChatGPT"); return }
                guard AXIsProcessTrusted() else {
                    fallback("Allow Semantic under Privacy & Security → \(controlPermissionName). If already enabled, remove and add the currently installed Semantic app, then retry.", settings: openControlSettings)
                    return
                }
                let ax = AXUIElementCreateApplication(running.processIdentifier)
                AXUIElementSetMessagingTimeout(ax, 0.25)
                func front() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier }
                poll(timeout: 8, { front() && !walk(ax).isEmpty }) { ready in
                    guard ready else { fallback("Open a new ChatGPT draft"); return }
                    guard let existing = composer(walk(ax)) else { fallback("Could not check ChatGPT for an existing draft. Open a new chat, then retry."); return }
                    if !empty(existing) || hasDraftAttachments(existing) {
                        fallback("ChatGPT already has an unsent draft. Finish or save it, then open a new chat and retry.")
                        return
                    }
                    guard menu(ax, named: "New Chat") else { fallback("Open a new ChatGPT draft"); return }
                    // New-chat controls must be present, not just an empty composer in an existing conversation.
                    poll(timeout: 8, {
                        guard front() else { return false }
                        let nodes = walk(ax)
                        guard let field = composer(nodes), empty(field) else { return false }
                        return (nodes.contains { label($0) == "Chat" } && nodes.contains { label($0) == "Work" })
                            || nodes.contains { ["What’s on the agenda today?", "What should we work on?", "What can I help with?", "What’s on your mind today?"].contains(string($0, kAXValueAttribute)) }
                    }) { fresh in
                        guard fresh, front() else { fallback("Could not verify a fresh ChatGPT draft"); return }
                        // Keep the user's current Chat/Work mode; both accept file attachments.
                        let nodes = walk(ax)
                        if let outside = nodes.first(where: { label($0) == "Don't work in a project" }) { _ = press(outside) }
                        guard let field = composer(walk(ax)), empty(field) else { fallback("ChatGPT draft changed"); return }
                        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, prompt as CFString) == .success else {
                            fallback("Paste into the new ChatGPT draft"); return
                        }
                        poll(timeout: 3, { front() && string(field, kAXValueAttribute).contains(prompt) }) { entered in
                            guard entered else { fallback("Could not verify the question"); return }
                            guard !files.isEmpty else {
                                busy = false; Toast.show("Question ready in ChatGPT · review and send", seconds: 4); return
                            }
                            guard files.allSatisfy({ Assistant.attachmentIssue($0) == nil }) else {
                                fallback("An attachment became unavailable. Restore access or remove it, then retry.")
                                return
                            }
                            copy(prompt, files: files)
                            let pasteCount = NSPasteboard.general.changeCount
                            guard front(), menu(ax, named: "Paste") else { fallback("Question ready; attach the copied files"); return }
                            // Scope attachment evidence to the composer ancestors, avoiding filenames in chat history.
                            poll(timeout: 30, {
                                guard front(), NSPasteboard.general.changeCount == pasteCount else { return false }
                                guard let current = composer(walk(ax)), string(current, kAXValueAttribute).contains(prompt) else { return false }
                                return attachmentsVerified(files, cards: attachmentCards(current, files: files))
                            }) { attached in
                                busy = false
                                if attached { Toast.show("\(files.count) file\(files.count == 1 ? "" : "s") attached in ChatGPT · review and send", seconds: 5) }
                                else { AssistantDraft.show(question: prompt, files: files, destination: url, reason: "Question ready; attachments could not be verified. Review the existing draft before retrying to avoid duplicate attachments.",
                                    retry: { edited, remaining in Assistant.ask(edited, files: remaining, app: true, to: .chatgpt) }) }
                            }
                        }
                    }
                }
            }
        }
    }
}
