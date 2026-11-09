import AppKit
import ApplicationServices

// axclick <app name> <mode: list|press|pos> [label]
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: axclick App list|press|pos [label]"); exit(1) }
guard AXIsProcessTrusted() else { print("NOT TRUSTED for Accessibility"); exit(2) }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == args[1] }) else { print("app not running"); exit(3) }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 2)
func s(_ e: AXUIElement, _ a: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v as? String
}
func kids(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success, let a = v as? [AXUIElement] else { return [] }
    return a
}
func frame(_ e: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, z: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &z) == .success else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(z as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func names(_ e: AXUIElement) -> [String] { [s(e, "AXTitle"), s(e, "AXDescription"), s(e, "AXValue"), s(e, "AXLabel"), s(e, "AXHelp"), s(e, "AXPlaceholderValue")].compactMap { $0 }.filter { !$0.isEmpty } }
var found: [(AXUIElement, String, String)] = []
func walk(_ e: AXUIElement, _ depth: Int) {
    if depth > 16 { return }
    let role = s(e, "AXRole") ?? "?"
    if args[2] == "list" { let n = names(e); if !n.isEmpty, ["AXButton","AXRadioButton","AXCheckBox","AXTextField","AXMenuButton","AXPopUpButton","AXStaticText","AXTextArea","AXLink"].contains(role) { print(String(repeating: " ", count: depth), role, n.joined(separator: " | ").prefix(90)) } }
    else if let label = args.count > 3 ? args[3] : nil, args[2] != "set", ["AXButton","AXRadioButton","AXCheckBox","AXMenuButton","AXPopUpButton","AXLink","AXStaticText","AXGroup"].contains(role), names(e).contains(where: { $0 == label }) { found.append((e, role, label)) }
    for k in kids(e) { walk(k, depth + 1) }
}
var wins: [AXUIElement] = []
var wv: CFTypeRef?
if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &wv) == .success, let w = wv as? [AXUIElement] { wins = w }
for w in wins where (frame(w)?.width ?? 0) > 400 { walk(w, 0) }
if args[2] == "list" { exit(0) }
if args[2] == "set" {
    guard args.count > 4 else { print("usage: set label value"); exit(1) }
    var fields: [AXUIElement] = []
    func find(_ e: AXUIElement, _ d: Int) {
        if d > 16 { return }
        let role = s(e, "AXRole") ?? "?"
        if ["AXTextField", "AXTextArea"].contains(role), names(e).contains(where: { $0.hasPrefix(args[3]) }) { fields.append(e) }
        for k in kids(e) { find(k, d + 1) }
    }
    for w in wins where (frame(w)?.width ?? 0) > 400 { find(w, 0) }
    guard let f = fields.first else { print("NO FIELD:", args[3]); exit(4) }
    AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let r = AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, args[4] as CFString)
    print(r == .success ? "set" : "set failed \(r.rawValue)")
    exit(0)
}
// prefer buttons
let pick = found.first(where: { $0.1 == "AXButton" || $0.1 == "AXRadioButton" || $0.1 == "AXCheckBox" }) ?? found.first
guard let (el, role, label) = pick else { print("NOT FOUND:", args.count > 3 ? args[3] : ""); exit(4) }
if args[2] == "pos" { if let f = frame(el) { print(Int(f.midX), Int(f.midY)) }; exit(0) }
let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
print(r == .success ? "pressed \(role) \(label)" : "press failed \(r.rawValue) for \(role) \(label)")
