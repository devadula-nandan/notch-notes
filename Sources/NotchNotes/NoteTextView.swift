import Cocoa
import NotchNotesCore

// Notes editor: placeholder, checkboxes drawn over "- [ ]", numbered and bulleted lists, ⌘-clickable links,
// dates tinted and, once they are due, filled and pulsing until the task is checked or the reminder dismissed
final class NoteTextView: ArrowTextView {
    typealias ListKind = NotchNotesCore.ListKind

    var onChange: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var placeholder = "Type your notes here..." { didSet { needsDisplay = true } }
    // The note shown; part of the key a dismissed reminder is stored under
    var noteName = ""
    // Whether the panel is expanded; a collapsed panel stays on screen (so never occluded), but nothing shows
    var isPanelOpen = false { didSet { updateTimers() } }
    private var boxes: [(range: NSRange, mark: NSRange, checked: Bool)] = []
    private var links: [(range: NSRange, url: URL)] = []
    // `state` is what the date was styled as; the status tick restyles when the clock says otherwise
    private var dates: [(range: NSRange, due: Date, text: String, state: ReminderState)] = []
    private var statusTimer: Timer?
    private var pulseTimer: Timer?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // The one edit made since the last didChangeText, so only its lines are restyled
    private var pendingEdit: (location: Int, length: Int, delta: Int, oldLength: Int)?
    private var editCount = 0
    private var observingUndo = false

    private static let checkboxRegex = ListText.checkboxRegex
    private static let numberedRegex = ListText.numberedRegex
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let linkColor = NSColor(red: 0.5, green: 0.72, blue: 1, alpha: 1)
    // Darker than systemRed so white text on it reaches 4.5:1 (about 5:1 solid), also at the low point of the pulse
    private static let dueColor = NSColor(srgbRed: 0.78, green: 0.16, blue: 0.12, alpha: 1)
    private static let dismissedKey = "dismissedReminders"
    private static let pulsePeriod = 1.2

    private var text: NSString { string as NSString }
    private var baseFont: NSFont { font ?? .monospacedSystemFont(ofSize: 13, weight: .regular) }
    private var baseAttrs: [NSAttributedString.Key: Any] { [.font: baseFont, .foregroundColor: inkColor] }

    // MARK: - Text helpers

    // The line containing `location`, without its line break
    private func lineRange(at location: Int) -> NSRange {
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    private func isBlank(_ range: NSRange) -> Bool {
        text.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
    }

    // An undoable edit; optionally leaves the caret at `caret`
    @discardableResult
    private func replace(_ range: NSRange, with replacement: String, caret: Int? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let caret { setSelectedRange(NSRange(location: caret, length: 0)) }
        return true
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        editCount += 1
        if editCount == 1, affectedRanges.count == 1, let new = replacementStrings?.first {
            let old = affectedRanges[0].rangeValue, length = (new as NSString).length
            pendingEdit = (old.location, length, length - old.length, textStorage?.length ?? 0)
        } else {
            pendingEdit = nil
        }
        return true
    }

    override func didChangeText() {
        // Several edits at once, or one that wasn't announced (or didn't happen as announced): restyle everything
        if editCount == 1, let edit = pendingEdit, textStorage?.length == edit.oldLength + edit.delta {
            restyle(edit.location, length: edit.length, delta: edit.delta)
        } else {
            restyle()
        }
        editCount = 0
        pendingEdit = nil
        super.didChangeText()
        onChange?()
    }

    // Undo and redo change the text without going through didChangeText
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimers()
        guard window != nil, !observingUndo else { return }
        observingUndo = true
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard note.object as AnyObject === window else { return }
        updateTimers()
    }

    @objc private func reduceMotionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updateTimers()
        needsDisplay = true
    }

    @objc private func undoChanged(_ note: Notification) {
        guard note.object as AnyObject === undoManager else { return }
        editCount = 0
        pendingEdit = nil
        restyle()
        onChange?()
    }

    // MARK: - Styling and drawing

    // Sit the text close under the toolbar; the rest of the vertical inset goes below the text
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: 2) }

    func restyle() {
        guard let ts = textStorage else { return }
        boxes = []
        links = []
        dates = []
        style(NSRange(location: 0, length: ts.length), in: ts)
    }

    // After one edit, only the lines it touched: restyling a long note in full on every key is slow,
    // as the whole text is laid out again
    private func restyle(_ location: Int, length: Int, delta: Int) {
        guard let ts = textStorage else { return }
        let lines = ListText.restyleRange(in: ts.string as NSString, editedAt: location, length: length)
        let oldEnd = NSMaxRange(lines) - delta   // where those lines ended before the edit

        // Boxes, links and dates in those lines are found again; the ones after them moved by `delta`
        func moved(_ r: NSRange) -> NSRange? {
            if r.location < lines.location { return r }
            return r.location >= oldEnd ? NSRange(location: r.location + delta, length: r.length) : nil
        }
        boxes = boxes.compactMap { b in
            guard let range = moved(b.range) else { return nil }
            return (range, NSRange(location: b.mark.location + range.location - b.range.location, length: b.mark.length), b.checked)
        }
        links = links.compactMap { l in moved(l.range).map { ($0, l.url) } }
        dates = dates.compactMap { d in moved(d.range).map { ($0, d.due, d.text, d.state) } }
        style(lines, in: ts)
    }

    // Underline links, hide "- [ ]" (a checkbox is drawn over it), dim checked items and find dates, in whole lines
    private func style(_ full: NSRange, in ts: NSTextStorage) {
        let charW = ("0" as NSString).size(withAttributes: baseAttrs).width
        ts.beginEditing()
        ts.setAttributes(baseAttrs, range: full)
        // Links are looked for one line at a time: given more, the detector also reads across line breaks,
        // and what it finds in a line would then depend on how much of the note is being restyled
        let all = ts.string as NSString
        all.enumerateSubstrings(in: full, options: .byLines) { line, lineRange, _, _ in
            guard let line, line.contains(".") || line.contains("://") else { return }
            Self.linkDetector?.enumerateMatches(in: line, range: NSRange(location: 0, length: lineRange.length)) { m, _, _ in
                guard let m, let url = m.url, url.scheme == "http" || url.scheme == "https" else { return }
                let range = NSRange(location: lineRange.location + m.range.location, length: m.range.length)
                self.links.append((range, url))
                ts.addAttributes([.foregroundColor: Self.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                  .underlineColor: Self.linkColor.withAlphaComponent(0.5)], range: range)
            }
        }
        Self.checkboxRegex.enumerateMatches(in: ts.string, range: full) { m, _, _ in
            guard let m else { return }
            let prefix = m.range(at: 1), body = m.range(at: 3)
            let checked = !isBlank(m.range(at: 2))
            boxes.append((prefix, m.range(at: 2), checked))
            ts.addAttribute(.foregroundColor, value: NSColor.clear, range: prefix)
            // Squeeze the hidden "- [ ]" down to the width of the drawn box
            let squeeze = (CGFloat(prefix.length) * charW - baseFont.pointSize) / CGFloat(prefix.length - 1)
            ts.addAttribute(.kern, value: -squeeze, range: NSRange(location: prefix.location, length: prefix.length - 1))
            if checked {
                // Strike only the words, not the spaces around them
                let words = text.substring(with: body)
                let lead = words.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let length = (words.trimmingCharacters(in: .whitespaces) as NSString).length
                ts.addAttributes([.foregroundColor: NSColor(white: 0.3, alpha: 1),
                                  .strikethroughColor: NSColor(white: 0.45, alpha: 1),
                                  .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: body.location + lead, length: length))
            }
        }
        // Dates, in lines that aren't checked off. Like links, a line at a time and only if it has a digit
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let now = Date()
        all.enumerateSubstrings(in: full, options: .byLines) { line, lineRange, _, _ in
            guard let line, line.contains(where: \.isNumber) else { return }
            if let m = Self.checkboxRegex.firstMatch(in: line, range: NSRange(location: 0, length: lineRange.length)),
               !(line as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces).isEmpty { return }
            for d in DateText.detect(in: line) {
                let range = NSRange(location: lineRange.location + d.range.location, length: d.range.length)
                guard !self.links.contains(where: { NSIntersectionRange($0.range, range).length > 0 }),
                      !dismissed.contains(Self.reminderKey(noteName: self.noteName, text: d.text, due: d.due)) else { continue }
                let state = DateText.state(of: d, now: now)
                self.dates.append((range, d.due, d.text, state))
                // The due fill is drawn behind the text; white and underlined keep it readable without relying on colour.
                // The tooltip is also what assistive technology reads, and it says how to stop the reminder.
                if state == .due {
                    ts.addAttributes([.foregroundColor: NSColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .toolTip: "Reminder due - right-click, or Ctrl-Return with the caret in it, to dismiss"], range: range)
                }
            }
        }
        ts.endEditing()
        typingAttributes = baseAttrs
        needsDisplay = true
        updateTimers()
    }

    // MARK: - Dates

    private static func reminderKey(noteName: String, text: String, due: Date) -> String {
        "\(noteName)|\(text)|\(Int(due.timeIntervalSince1970))"
    }

    // Both timers run only while there is something to do. The status tick repeats rather than fires once at the
    // deadline, as a Timer doesn't count the time the Mac sleeps: the first tick after waking sets things right.
    private func updateTimers() {
        if dates.isEmpty {
            statusTimer?.invalidate()
            statusTimer = nil
        } else if statusTimer == nil {
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.statusTick() }
            t.tolerance = 3
            RunLoop.main.add(t, forMode: .common)
            statusTimer = t
        }

        let pulsing = !reduceMotion && isPanelOpen && window?.occlusionState.contains(.visible) == true && dates.contains { $0.state == .due }
        if !pulsing {
            pulseTimer?.invalidate()
            pulseTimer = nil
        } else if pulseTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pulseTick() }
            RunLoop.main.add(t, forMode: .common)
            pulseTimer = t
        }
    }

    private func statusTick() {
        let now = Date()
        let changed = dates.contains { DateText.state(of: DetectedDate(range: $0.range, text: $0.text, due: $0.due), now: now) != $0.state }
        if changed { restyle() }
    }

    private func pulseTick() {
        for d in dates where d.state == .due {
            for r in dateRects(d.range) { setNeedsDisplay(r.insetBy(dx: -4, dy: -4)) }
        }
    }

    // Where a date is: one rect per line it wraps over
    private func dateRects(_ range: NSRange) -> [CGRect] {
        guard let lm = layoutManager, let tc = textContainer else { return [] }
        var rects: [CGRect] = []
        lm.enumerateEnclosingRects(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                   withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
            rects.append(r.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return rects
    }

    // Behind the text, so only a due date's colour and underline touch the text itself
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !dates.isEmpty else { return }
        let phase = 0.5 + 0.5 * sin(2 * .pi * Date().timeIntervalSinceReferenceDate / Self.pulsePeriod)
        for d in dates {
            let color = d.state == .due
                ? Self.dueColor.withAlphaComponent(reduceMotion ? 1 : 0.55 + 0.45 * phase)
                : NSColor.controlAccentColor.withAlphaComponent(0.22)
            color.setFill()
            for r in dateRects(d.range) where r.insetBy(dx: -4, dy: -4).intersects(rect) {
                NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: 0), xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    // Right-click a due date to dismiss its reminder; from the keyboard (Ctrl-Return), the date at the caret
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let caret = selectedRange().location
        let index = mouse.contains(event.type) ? characterIndex(at: convert(event.locationInWindow, from: nil)) : caret
        guard let i = index,
              let d = dates.first(where: { $0.state == .due && (NSLocationInRange(i, $0.range) || (!mouse.contains(event.type) && i == NSMaxRange($0.range))) })
        else { return menu }
        let item = NSMenuItem(title: "Dismiss Reminder", action: #selector(dismissReminder(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Self.reminderKey(noteName: noteName, text: d.text, due: d.due)
        menu?.insertItem(item, at: 0)
        menu?.insertItem(.separator(), at: 1)
        return menu
    }

    // Kept in UserDefaults, as notes are plain text with nowhere to keep it. The same date text twice in a note goes together.
    @objc private func dismissReminder(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed.append(key)
        UserDefaults.standard.set(dismissed, forKey: Self.dismissedKey)
        restyle()
    }

    private func boxRect(for range: NSRange) -> CGRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let s = baseFont.pointSize
        return CGRect(x: r.minX + (r.width - s) / 2, y: r.midY - s / 2, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for box in boxes {
            let rect = boxRect(for: box.range)
            guard rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if box.checked {
                // Same look as the active checklist button: soft green wash, solid green tick
                NSColor.systemGreen.withAlphaComponent(0.24).setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: rect.minX + rect.width * 0.23, y: rect.midY))
                check.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY - rect.height * 0.27))
                check.line(to: NSPoint(x: rect.maxX - rect.width * 0.23, y: rect.minY + rect.height * 0.27))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                NSColor.systemGreen.setStroke()
                check.stroke()
            } else {
                path.lineWidth = 1.2
                NSColor(white: 0.55, alpha: 1).setStroke()
                path.stroke()
            }
        }

        if string.isEmpty {
            let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
            placeholder.draw(at: NSPoint(x: x, y: textContainerOrigin.y), withAttributes: [
                .foregroundColor: NSColor(white: 0.5, alpha: 1), .font: baseFont,
            ])
        }
    }

    // MARK: - Lists

    var listKindAtCaret: ListKind? {
        let line = lineRange(at: selectedRange().location)
        if Self.checkboxRegex.firstMatch(in: string, range: line) != nil { return .checkbox }
        if Self.numberedRegex.firstMatch(in: string, range: line) != nil { return .numbered }
        return nil
    }

    // Toggle "- [ ] " or "1. " on the current / selected lines
    func toggleList(_ kind: ListKind) {
        let range = text.lineRange(for: selectedRange())
        let block = text.substring(with: range)
        let result = ListText.toggled(block, kind: kind)
        let end = range.location + (result.text as NSString).length - (block.hasSuffix("\n") ? 1 : 0)
        if replace(range, with: result.text, caret: end), kind == .numbered, !result.removing { renumber(after: end) }
    }

    // Keep a numbered list sequential: renumber the items that follow the line at `location`
    private func renumber(after location: Int) {
        let edits = ListText.renumbering(string, after: location)
        guard !edits.isEmpty else { return }
        let caret = selectedRange()
        // Last one first, so the ranges of the earlier ones still hold
        for e in edits.reversed() where shouldChangeText(in: e.range, replacementString: e.number) {
            textStorage?.replaceCharacters(in: e.range, with: e.number)
        }
        didChangeText()
        setSelectedRange(caret)
    }

    // Tab / Shift-Tab move the list items on the current / selected lines in or out a level
    private func shiftIndent(outdent: Bool) -> Bool {
        let sel = selectedRange(), range = text.lineRange(for: sel)
        let block = text.substring(with: range)
        guard let shifted = ListText.indented(block, outdent: outdent) else { return false }
        guard shifted != block, replace(range, with: shifted) else { return true }
        let length = (shifted as NSString).length
        if sel.length == 0 {
            setSelectedRange(NSRange(location: max(sel.location + length - range.length, range.location), length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location, length: length - (shifted.hasSuffix("\n") ? 1 : 0)))
        }
        return true
    }

    override func insertTab(_ sender: Any?) {
        if !shiftIndent(outdent: false) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !shiftIndent(outdent: true) { super.insertBacktab(sender) }
    }

    // MARK: - Editing

    // The character under a point, if the point is on one
    private func characterIndex(at p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else { return nil }
        let pt = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: pt, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(pt) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    // The link under a point, if the point is on its text
    private func link(at p: NSPoint) -> URL? {
        guard !links.isEmpty, let i = characterIndex(at: p) else { return nil }
        return links.first { NSLocationInRange(i, $0.range) }?.url
    }

    // Click a checkbox to toggle it; ⌘-click a link to open it (a plain click still edits it)
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let url = link(at: p) {
            onOpenLink?(url)
        } else if let box = boxes.first(where: { boxRect(for: $0.range).insetBy(dx: -4, dy: -4).contains(p) }) {
            replace(box.mark, with: box.checked ? " " : "x")
            // Checked items go below the unchecked ones of their list
            if let list = ListText.checkedLast(string, at: box.range.location) {
                replace(list.range, with: list.text, caret: selectedRange().location)
            }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Backspace with the caret inside or right after a list marker removes it in one go:
    // a number is cleared from its line, a checkbox takes its whole line with it
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange(), line = lineRange(at: sel.location)
        guard sel.length == 0 else { return super.deleteBackward(sender) }

        if let n = Self.numberedRegex.firstMatch(in: string, range: line) {
            let marker = NSRange(location: n.range(at: 2).location, length: n.range(at: 3).location - n.range(at: 2).location)
            if sel.location > marker.location, sel.location <= NSMaxRange(marker) {
                replace(marker, with: "", caret: marker.location)
                return
            }
        }

        if let m = Self.checkboxRegex.firstMatch(in: string, range: line) {
            let prefix = m.range(at: 1)
            var textStart = NSMaxRange(prefix)
            if textStart < text.length, text.character(at: textStart) == 32 { textStart += 1 }
            if sel.location > prefix.location, sel.location <= textStart {
                // Take the preceding line break so the caret lands at the end of the previous line
                let range = line.location > 0 ? NSRange(location: line.location - 1, length: line.length + 1)
                                              : text.lineRange(for: line)
                replace(range, with: "", caret: range.location)
                return
            }
        }

        super.deleteBackward(sender)
    }

    // Enter on a list line continues the list; Enter on an empty item ends it
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange(), line = lineRange(at: sel.location)
        guard sel.length == 0 else { return super.insertNewline(sender) }
        let indent: String, body: NSRange, next: String
        if let n = Self.numberedRegex.firstMatch(in: string, range: line) {
            indent = text.substring(with: n.range(at: 1))
            body = n.range(at: 3)
            next = "\((Int(text.substring(with: n.range(at: 2))) ?? 0) + 1). "
        } else if let m = Self.checkboxRegex.firstMatch(in: string, range: line) {
            indent = text.substring(with: NSRange(location: line.location, length: m.range(at: 1).location - line.location))
            body = m.range(at: 3)
            next = "- [ ] "
        } else if let b = ListText.bulletRegex.firstMatch(in: string, range: line) {
            indent = text.substring(with: b.range(at: 1))
            body = b.range(at: 3)
            next = text.substring(with: b.range(at: 2)) + " "
        } else {
            return super.insertNewline(sender)
        }

        if isBlank(body) {
            insertText(indent, replacementRange: line)
        } else {
            insertText("\n" + indent + next, replacementRange: sel)
            renumber(after: selectedRange().location)   // does nothing on a checkbox line
        }
    }
}
