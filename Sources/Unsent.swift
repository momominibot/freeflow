import AppKit
import ApplicationServices
import SwiftUI

// A dictation that did not reach a text box is never lost: it is already in the history, and when FreeFlow can tell that it did not
// arrive, this card appears with the words so you can copy them. It is clickable without taking your keyboard focus, so the box you
// were in stays the box you are in.

// MARK: - Telling whether the words arrived (pure where it can be, so it can be tested)

extension Inserter {
    enum Landing: Equatable {
        case editable            // a text box that shows its own text: arrival can be checked
        case notText(String)     // the focus is on something that is not a text box (a list, a button, the desktop)
        case unknown             // a web page, an app that does not describe itself: paste and trust it, as always
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let nonTextRoles: Set<String> = ["AXButton", "AXOutline", "AXTable", "AXList", "AXRow", "AXCell", "AXColumn", "AXStaticText", "AXImage",
                                            "AXToolbar", "AXMenuBar", "AXMenuBarItem", "AXMenuItem", "AXMenu", "AXPopUpButton", "AXCheckBox",
                                            "AXRadioButton", "AXSlider", "AXTabGroup", "AXScrollBar", "AXScrollArea", "AXBrowser", "AXDockItem"]

    static func classify(role: String, settable: Bool) -> Landing {
        if textRoles.contains(role) || settable { return .editable }
        if nonTextRoles.contains(role) { return .notText(role) }
        return .unknown
    }

    /// True when the box changed, false when it did not (the paste was ignored), nil when it cannot be read.
    static func arrived(before: String?, after: String?) -> Bool? {
        guard let b = before, let a = after else { return nil }
        return a != b
    }

    /// What the focus is on right now, and the text in it (so a later look can tell whether the paste changed it).
    static func look() -> (landing: Landing, element: AXUIElement?, before: String?) {
        guard let el = focusedElement() else { return (.unknown, nil, nil) }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let landing = classify(role: roleRef as? String ?? "", settable: isSettable(el))
        return (landing, el, landing == .editable ? readValue(el) : nil)
    }

    /// Looks at the box again after a paste: twice, half a second apart, before calling it a failure.
    static func confirmArrival(element: AXUIElement, before: String, completion: @escaping (Bool) -> Void) {
        func look(_ left: Int) {
            if arrived(before: before, after: readValue(element)) != false { return completion(true) }
            guard left > 0 else { return completion(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { look(left - 1) }
        }
        look(1)
    }
}

// MARK: - The card

final class UnsentModel: ObservableObject {
    @Published var text = ""
    @Published var reason = ""
    @Published var copied = false
    @Published var canPasteAgain = true
}

struct UnsentView: View {
    @ObservedObject var m: UnsentModel
    let copy: () -> Void
    let pasteAgain: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Emblem(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This did not reach a text box").font(Fonts.serif(18)).foregroundColor(RT.plum)
                    Text(m.reason).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(m.text)
                    .font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 150)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RT.paper2))
            HStack(spacing: 10) {
                Button(m.copied ? "Copied" : "Copy", action: copy).buttonStyle(PrimaryButton(small: true))
                if m.canPasteAgain { Button("Paste again", action: pasteAgain).buttonStyle(GhostButton()) }
                Button("Close", action: close).buttonStyle(GhostButton())
                Spacer(minLength: 0)
            }
            Text("It is also saved in your history on the Home page.").font(Fonts.sans(11.5, .medium)).foregroundColor(RT.ink3)
        }
        .padding(18)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: RT.radius, style: .continuous).fill(RT.card))
        .shadow(color: RT.lift2, radius: 18, y: 8)
        .padding(26)
    }
}

final class UnsentCard {
    private let panel: PromptPanel
    private let model = UnsentModel()
    private var timer: Timer?
    private var onPasteAgain: (String) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    var isShown: Bool { panel.isVisible }
    var text: String { model.text }
    static let stayFor: TimeInterval = 300

    init() {
        panel = PromptPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "FreeFlow: not typed"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: UnsentView(m: model,
                                                               copy: { [weak self] in self?.copyTapped() },
                                                               pasteAgain: { [weak self] in self?.pasteAgainTapped() },
                                                               close: { [weak self] in self?.hide() }))
    }

    func show(text: String, reason: String, alreadyCopied: Bool = false, onPasteAgain: @escaping (String) -> Void) {
        model.text = text
        model.reason = reason
        model.copied = alreadyCopied
        model.canPasteAgain = true
        self.onPasteAgain = onPasteAgain
        if let host = panel.contentView as? NSHostingView<UnsentView> { panel.setContentSize(host.fittingSize) }
        place()
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.stayFor, repeats: false) { [weak self] _ in self?.hide() }
        log("unsent: shown (\(reason))")
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }

    private func copyTapped() {
        Inserter.copy(model.text)
        model.copied = true
        log("unsent: copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.hide() }
    }

    private func pasteAgainTapped() {
        let t = model.text
        hide()
        log("unsent: pasting again")
        onPasteAgain(t)
    }

    /// Bottom right of the screen with the pointer, clear of the call card at the top and the recording bar in the middle.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width + 8, y: vf.minY - 8))
    }
}
