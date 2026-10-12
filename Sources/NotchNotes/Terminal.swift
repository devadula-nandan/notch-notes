import Cocoa
import SwiftTerm

// The terminals shown over the notes or the page: login shells, kept running while the notes or a page show

extension NotchWindowController {
    var terminalShown: Bool { terminal?.isHidden == false }
    var terminalIndex: Int { terminals.firstIndex { $0 === terminal } ?? 0 }

    func toggleTerminal() {
        let term = terminal ?? makeTerminal()
        terminal = term
        term.isHidden.toggle()
        terminalChanged()
    }

    // The dots under the terminal: one shell each, and + starts another
    func showTerminal(_ index: Int) {
        guard terminals.indices.contains(index), terminals[index] !== terminal else { return }
        terminal?.isHidden = true
        terminal = terminals[index]
        terminal?.isHidden = false
        terminalChanged()
        flash("Terminal \(index + 1) of \(terminals.count)")
    }

    func newTerminal() {
        _ = makeTerminal()
        showTerminal(terminals.count - 1)
    }

    private func terminalChanged() {
        scrollView.isHidden = terminalShown || webView != nil
        webHost.isHidden = terminalShown || webView == nil
        closeTray()
        layoutControls()
        focusContent()
    }

    private func makeTerminal() -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: scrollView.frame)
        term.font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        term.nativeBackgroundColor = .black
        term.nativeForegroundColor = inkColor
        term.processDelegate = self
        // The thinnest scroll bar there is, over a black strip: a coloured line would otherwise run on under it to the edge
        if let bar = term.subviews.first(where: { $0 is NSScroller }) as? NSScroller {
            bar.controlSize = .mini
            let strip = NSView(frame: bar.frame)
            strip.wantsLayer = true
            strip.layer?.backgroundColor = .black
            strip.autoresizingMask = bar.autoresizingMask
            term.addSubview(strip, positioned: .below, relativeTo: bar)
        }
        term.isHidden = true
        panel.addSubview(term, positioned: .above, relativeTo: scrollView)
        terminals.append(term)
        // A login shell in the home folder, like a new Terminal window
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        term.startProcess(executable: shell, environment: Terminal.getEnvironmentVariables() + ["SHELL=\(shell)"],
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: NSHomeDirectory())
        return term
    }
}

extension NotchWindowController: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // A shell exited: the one next to it takes its place. After the last one, what was under the terminal
    // shows again, and opening it starts a new shell
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let index = terminals.firstIndex(where: { $0 === source }) else { return }
        terminals.remove(at: index)
        source.removeFromSuperview()
        guard source === terminal else { return layoutControls() }
        terminal = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)]
        terminal?.isHidden = source.isHidden
        terminalChanged()
    }
}
