import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Private bridge (AXUIElement <-> CGWindowID)
// The only non-public API used. It lets us map the CGWindowID we get from
// CGWindowList onto the matching Accessibility window element, which we need
// both to read the real window title and to raise a specific window.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Model

struct WindowInfo {
    let cgID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let ax: AXUIElement?
}

let axTrusted = AXIsProcessTrusted()
var selfPID = getpid()

// Cache AX windows per app: [CGWindowID, AXUIElement]. Filled lazily so we do
// at most one Accessibility pass per app, no matter how many windows we query.
var axCache: [pid_t: [(CGWindowID, AXUIElement)]] = [:]

// MARK: - Accessibility helpers

func axWindows(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    // Ask background apps to expose their UI so we can read their windows.
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return []
    }
    return windows
}

func axTitle(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
          let s = value as? String else { return nil }
    return s.isEmpty ? nil : s
}

func axCacheFor(pid: pid_t) -> [(CGWindowID, AXUIElement)] {
    if let cached = axCache[pid] { return cached }
    var list: [(CGWindowID, AXUIElement)] = []
    for element in axWindows(pid: pid) {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(element, &id) == .success, id != 0 {
            list.append((id, element))
        }
    }
    axCache[pid] = list
    return list
}

func axElement(cgID: CGWindowID, pid: pid_t) -> AXUIElement? {
    axCacheFor(pid: pid).first(where: { $0.0 == cgID })?.1
}

// MARK: - Listing

func listWindows(includeOffscreen: Bool = false) -> [WindowInfo] {
    let options: CGWindowListOption = includeOffscreen
        ? [.optionAll, .excludeDesktopElements]
        : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    var result: [WindowInfo] = []

    for dict in raw {
        // layer 0 == normal application windows (skips menus, status bar, dock…)
        guard let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
        guard let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0 else { continue }
        guard let cgID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value, cgID != 0 else { continue }
        if pid == selfPID { continue } // our own CLI window (if any)

        let owner = (dict[kCGWindowOwnerName as String] as? String) ?? "?"

        // kCGWindowName is instant and needs no Accessibility, but on macOS 10.15+
        // it is empty unless Screen Recording permission is granted. Prefer it when
        // available (fast path); otherwise fall back to Accessibility only when we
        // actually need to focus.
        let cgName = ((dict[kCGWindowName as String] as? String) ?? "").trimmingCharacters(in: .whitespaces)

        var title = owner
        var ax: AXUIElement?
        if !cgName.isEmpty {
            title = cgName
        } else if axTrusted, let e = axElement(cgID: cgID, pid: pid) {
            if let t = axTitle(e) { title = t }
            ax = e
        } else {
            ax = nil
        }

        result.append(WindowInfo(cgID: cgID, pid: pid, ownerName: owner, title: title, ax: ax))
    }

    return result
}

// MARK: - Focusing

func unminimizeIfNeeded(_ element: AXUIElement) {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success,
       let minimized = value as? Bool, minimized {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
}

func raise(_ w: WindowInfo) {
    // Resolve the AX element lazily: only the one window we're about to focus,
    // so we don't pay the per-app Accessibility cost across the whole list.
    var el = w.ax
    if el == nil, axTrusted {
        el = axElement(cgID: w.cgID, pid: w.pid)
    }

    if let ax = el { unminimizeIfNeeded(ax) }
    if let app = NSRunningApplication(processIdentifier: w.pid) {
        app.activate(options: [])
    }
    if let ax = el {
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
}

func bestMatch(over windows: [WindowInfo], query: String) -> WindowInfo? {
    let q = query.lowercased()
    var best: (score: Int, w: WindowInfo)?

    for w in windows {
        let hay = "\(w.ownerName) \(w.title)".lowercased()
        let score: Int
        if hay.hasPrefix(q) {
            score = 1000 - w.title.count // prefix match ranked highest
        } else if let r = hay.range(of: q) {
            score = 500 - r.lowerBound.utf16Offset(in: hay) // earlier match better
        } else {
            continue
        }
        if best == nil || score > best!.score { best = (score, w) }
    }
    return best?.w
}

func focusQuery(_ query: String, includeOffscreen: Bool = false) {
    if !axTrusted { warnNoAccessibility() }

    let trimmed = query.trimmingCharacters(in: .whitespaces)
    // Default: on-screen windows only (~50 ms, clean). Off-screen/minimized
    // enumeration is slow (~450 ms) and noisy, so it's opt-in via --all.
    let windows = listWindows(includeOffscreen: includeOffscreen)

    // Exact window number from `list` / `list --all` output.
    if let n = Int(trimmed) {
        let cgID = CGWindowID(n)
        if let w = windows.first(where: { $0.cgID == cgID }) {
            raise(w)
            print("Focused: \(w.ownerName) — \(w.title)")
            return
        }
        print("No window with number \(n)")
        return
    }

    // Fuzzy text match on "app title".
    if let w = bestMatch(over: windows, query: trimmed) {
        raise(w)
        print("Focused: \(w.ownerName) — \(w.title)")
        return
    }
    print("No window matched '\(trimmed)'")
}

// MARK: - Interactive

func interactive() {
    if !axTrusted { warnNoAccessibility() }

    let windows = listWindows()
    if windows.isEmpty {
        print("No open windows found.")
        return
    }

    print("Open windows:")
    for (i, w) in windows.enumerated() {
        print("  \(String(format: "%2d", i + 1)). \(w.ownerName) — \(w.title)")
    }
    print("Enter a number or a query > ", terminator: "")

    guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return }

    if let n = Int(line), n >= 1, n <= windows.count {
        raise(windows[n - 1])
        print("Focused: \(windows[n - 1].ownerName) — \(windows[n - 1].title)")
    } else {
        focusQuery(line)
    }
}

// MARK: - Output

func printList(_ windows: [WindowInfo]) {
    if windows.isEmpty { print("No open windows found."); return }
    let appWidth = (windows.map { $0.ownerName.count }.max() ?? 0)
    for w in windows {
        let app = w.ownerName.padding(toLength: appWidth, withPad: " ", startingAt: 0)
        print("\(String(format: "%6d", Int(w.cgID)))   \(app)   \(w.title)")
    }
}

func printJSON(_ windows: [WindowInfo]) {
    let arr = windows.map {
        ["id": Int($0.cgID), "pid": Int($0.pid), "app": $0.ownerName, "title": $0.title]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func warnNoAccessibility() {
    fputs("⚠️  Accessibility permission is not granted.\n", stderr)
    fputs("To read window titles and focus a specific window, enable it for your terminal:\n", stderr)
    fputs("System Settings > Privacy & Security > Accessibility\n", stderr)
}

func printUsage() {
    print("""
    windower — list and focus macOS windows.

    Usage:
      windower list [--json] [--all]   List open windows (--all includes minimized/other spaces)
      windower focus <query>           Focus an on-screen window (by number from `list`, or text)
      windower focus --all <query>     Also search minimized / other-space windows (slower)
      windower pick                    Interactive picker (on-screen windows)
      windower --help                  Show this help

    Titles and per-window focusing need Accessibility permission.
    """)
    if !axTrusted {
        fputs("⚠️  Accessibility permission is not granted. Enable it for your terminal in\nSystem Settings > Privacy & Security > Accessibility.\n", stderr)
    }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("-h") || args.contains("--help") || args.contains("help") {
    printUsage()
} else if args.isEmpty {
    printUsage()
} else {
    switch args[0] {
    case "list":
        let all = args.contains("--all")
        let windows = listWindows(includeOffscreen: all)
        if args.contains("--json") {
            printJSON(windows)
        } else {
            printList(windows)
        }
        if !axTrusted { warnNoAccessibility() }
    case "focus":
        guard args.count > 1 else {
            printUsage()
            exit(1)
        }
        let rest = args.dropFirst().map { $0 }
        let includeOffscreen = rest.contains("--all")
        let query = rest.filter { $0 != "--all" }.joined(separator: " ")
        guard !query.isEmpty else {
            printUsage()
            exit(1)
        }
        focusQuery(query, includeOffscreen: includeOffscreen)
    case "pick":
        interactive()
    default:
        printUsage()
        exit(1)
    }
}
