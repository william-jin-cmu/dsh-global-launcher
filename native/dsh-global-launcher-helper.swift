// dsh-global-launcher helper: a global hotkey that opens a small prompt bar from anywhere.
//
//   dsh-global-launcher-helper [--hotkey shift+cmd+space] [--context-hotkey option+cmd+space]
//                             [--placeholder "Ask DSH anything…"] [--max-chars 6000]
//                             [--ignore-bundle <id or prefix*>]... [--exclude-bundle <id>]...
//       -> {"ready":true,"hotkey":"...","contextHotkey":"..."?}  once the hotkeys are registered
//          {"error":"bad_hotkey"} / {"error":"hotkey_unavailable"}   then exit 2
//          {"shown":true,"context":false}                       each time the bar opens
//          {"submit":{"text":"...","screenshot":"/tmp/x.png"?,"context":{...}?,"target":"new"|"last",
//                     "workspaceId":"..."?,"model":{"provider":"...","id":"..."}?,"openMain":true}}   on Return
//          {"prefs":{"createMore":false,"openMain":true,"target":"new","workspaceId":"","model":null}}
//               whenever the user changes a switch, the target, the workspace or the model
//       <- on stdin (exits on EOF):
//          {"op":"show","context":true?} | {"op":"hide"} | {"op":"toggle"}
//          {"op":"options","workspaces":[{"id","title"}],"models":[{"provider","id","name","group"}],
//           "defaultWorkspaceId":"...","defaultModel":{"provider","id"},"hasLast":true,"prefs":{...}}                       what the bar offers and what it remembered
//          {"op":"done","message":"Started in my-project"}      the host accepted the last submit: confirm, then close
//          {"op":"failed","message":"..."}                      it did not: show why, keep the text
//          {"op":"submit","text":"...","screenshot":true?,"context":true?,"pid":123?}
//               submit without the bar (scripts, tests), capturing the frontmost window (or the app `pid`) when asked
//          {"op":"activate","bundlePrefixes":["com.deepseek.harness"]}
//               bring the app this helper runs under to the front, if its bundle id has one of the prefixes
//
// The bar can attach two things. A screenshot (needs Screen Recording): the context hotkey goes straight to the
// system's region picker (drag an area, or Space then click for a window; Esc cancels) and the bar opens afterwards
// with the picture in it; ⌘1 in the bar does the same, or removes the picture. And the text, title, address and
// selection of the window the user was in (needs Accessibility), read when the hotkey is pressed and sent when its
// chip (⌘2) is on. A screenshot that is not sent is deleted when the bar closes; one that is sent belongs to the host.
//
// The hotkeys are Carbon hotkeys, so they need no Accessibility or Input Monitoring permission.

import Cocoa
import Carbon.HIToolbox

// uses: native/lib/window-reader.swift

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let keyCodes: [String: Int] = [
    "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
    "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "`": kVK_ANSI_Grave, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
]

/// "option+shift+space" -> (keyCode, carbon modifiers). Needs one key and at least one modifier.
func parseHotkey(_ spec: String) -> (UInt32, UInt32)? {
    var mods: UInt32 = 0
    var key: Int?
    for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch part {
        case "cmd", "command", "meta", "super": mods |= UInt32(cmdKey)
        case "ctrl", "control": mods |= UInt32(controlKey)
        case "alt", "option", "opt": mods |= UInt32(optionKey)
        case "shift": mods |= UInt32(shiftKey)
        default:
            guard key == nil, let code = keyCodes[part] else { return nil }
            key = code
        }
    }
    guard let code = key, mods != 0 else { return nil }
    return (UInt32(code), mods)
}

/// The prompt: a few lines of text with a placeholder. Return sends, Shift-Return breaks the line.
final class PromptView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    var onChange: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onChange?()
    }
}

final class Panel: NSPanel {
    var onChipKey: ((Int) -> Void)?
    var onSend: (() -> Void)?
    override var canBecomeKey: Bool { true }

    // An accessory app has no menu bar, so the Edit shortcuts have to be routed by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "1": onChipKey?(0); return true
        case "2": onChipKey?(1); return true
        case "\r": onSend?(); return true
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

/// A flat button of the bar: an optional icon, a title, an optional chevron. Gray throughout; it lights up a
/// little under the pointer and a little more when it is on.
final class BarButton: NSControl {
    var isOn = false { didSet { restyle() } }
    var title: String { didSet { label.stringValue = title; label.isHidden = title.isEmpty; restyle() } }
    /// A quieter title, for a key hint next to an icon.
    var quietTitle = false { didSet { restyle() } }
    /// A tag rather than a toggle: it is always on, so it does not shout about it.
    var isTag = false { didSet { restyle() } }
    override var isEnabled: Bool { didSet { restyle() } }
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let chevronView = NSImageView()
    private var hovering = false

    init(icon: String? = nil, title: String = "", chevron: Bool = false, target: AnyObject, action: Selector) {
        self.title = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title
        label.isHidden = title.isEmpty
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.image = icon.flatMap { symbol($0, size: 12.5) }
        iconView.isHidden = icon == nil
        chevronView.image = symbol("chevron.down", size: 8.5, weight: .medium)
        chevronView.isHidden = !chevron
        for view in [iconView, chevronView] { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let stack = NSStackView(views: [iconView, label, chevronView])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setIcon(_ name: String) { iconView.image = symbol(name, size: 12.5) }

    // The whole pill is one target; the label and the icons inside take no clicks of their own.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { sendAction(action, to: target) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let strength: CGFloat = !isEnabled ? 0 : (isTag ? (hovering ? 0.11 : 0.07) : (isOn ? 0.12 : (hovering ? 0.06 : 0)))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(strength).cgColor
        }
        let tint: NSColor = !isEnabled ? .quaternaryLabelColor : (isOn && !isTag ? .labelColor : .secondaryLabelColor)
        label.textColor = quietTitle && isEnabled ? (isOn ? .secondaryLabelColor : .tertiaryLabelColor) : tint
        label.font = .systemFont(ofSize: quietTitle ? 11 : 12.5, weight: quietTitle || (isOn && !isTag) ? .medium : .regular)
        iconView.contentTintColor = tint
        chevronView.contentTintColor = isEnabled ? .tertiaryLabelColor : .quaternaryLabelColor
    }
}

/// The attached screenshot, small. A click takes it off again.
final class Thumbnail: NSControl {
    private let imageView = NSImageView()
    private var widthConstraint: NSLayoutConstraint!
    var image: NSImage? {
        didSet {
            imageView.image = image
            // As wide as the picture's shape asks for, within reason.
            let size = image?.size ?? .zero
            widthConstraint.constant = size.height > 0 ? min(160, max(40, 56 * size.width / size.height)) : 56
        }
    }

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        toolTip = "Remove the screenshot (⌘1)"
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 56)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        viewDidChangeEffectiveAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }
}

/// A small gray switch: the system one is tinted with the accent color, and the bar keeps that for the send button.
final class MiniSwitch: NSControl {
    var state: NSControl.StateValue = .off { didSet { restyle(animated: true) } }
    private let knob = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 15))
        wantsLayer = true
        layer?.cornerRadius = 7.5
        knob.cornerRadius = 5.5
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knob)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 15).isActive = true
        restyle(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    private func restyle(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let on = state == .on
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(on ? 0.55 : 0.16).cgColor
            knob.backgroundColor = (on ? NSColor.windowBackgroundColor : NSColor.labelColor.withAlphaComponent(0.75)).cgColor
        }
        knob.frame = CGRect(x: on ? 13 : 2, y: 2, width: 11, height: 11)
        CATransaction.commit()
    }
}

/// What the bar remembers between uses. The host keeps it on disk and hands it back at start.
struct Prefs {
    var createMore = false
    var openMain = true
    /// "new" starts a session, "last" continues the most recent one.
    var target = "new"
    /// Empty means the workspace used most recently.
    var workspaceId = ""
    /// Empty provider means the default model.
    var modelProvider = ""
    var modelId = ""

    var json: [String: Any] {
        ["createMore": createMore, "openMain": openMain, "target": target, "workspaceId": workspaceId,
         "model": modelProvider.isEmpty ? NSNull() : ["provider": modelProvider, "id": modelId] as Any]
    }

    mutating func merge(_ raw: [String: Any]) {
        if let v = raw["createMore"] as? Bool { createMore = v }
        if let v = raw["openMain"] as? Bool { openMain = v }
        if let v = raw["target"] as? String, v == "new" || v == "last" { target = v }
        if let v = raw["workspaceId"] as? String { workspaceId = v }
        if let model = raw["model"] as? [String: Any], let provider = model["provider"] as? String, let id = model["id"] as? String {
            modelProvider = provider
            modelId = id
        }
    }
}

enum Attachment { case pending, ready, denied, unavailable }

/// What was captured from the window the user was in when the bar opened.
final class Capture {
    var snap: Snapshot?
    var contextState = Attachment.pending
    var shotPath: String?
    var shotState = Attachment.pending

    func discardShot() {
        if let path = shotPath { try? FileManager.default.removeItem(atPath: path) }
        shotPath = nil
    }
}

struct CaptureOptions {
    var maxChars = 6000
    var ignoreBundles = Set<String>()
    var excludeBundles = Set<String>()
}

var captureOptions = CaptureOptions()

/// A set entry ending in `*` matches by prefix.
func bundleMatches(_ bundle: String, _ set: Set<String>) -> Bool {
    if set.contains(bundle) { return true }
    return set.contains { $0.hasSuffix("*") && bundle.hasPrefix($0.dropLast()) }
}

/// The app whose window gets attached: the frontmost one that is neither DSH itself nor excluded.
func captureTarget() -> pid_t? {
    for pid in pidsFrontToBack().prefix(4) {
        guard pid != getpid(), let running = NSRunningApplication(processIdentifier: pid) else { continue }
        let bundle = running.bundleIdentifier ?? ""
        if bundleMatches(bundle, captureOptions.excludeBundles) || bundleMatches(bundle, captureOptions.ignoreBundles) { continue }
        return pid
    }
    return nil
}

/// Reads the target window off the main thread; `done` runs on the main thread after each half finishes.
func capture(pid: pid_t?, into result: Capture, windowShot: Bool, done: @escaping () -> Void) {
    guard let pid = pid else {
        result.contextState = .unavailable
        result.shotState = .unavailable
        done()
        return
    }
    if AXIsProcessTrusted() {
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = snapshot(pid: pid, maxChars: captureOptions.maxChars, budgetMs: 700)
            DispatchQueue.main.async {
                result.snap = snap
                result.contextState = snap == nil ? .unavailable : .ready
                done()
            }
        }
    } else {
        // The app name needs no permission, so the chip can still say what it would attach.
        if let running = NSRunningApplication(processIdentifier: pid) {
            var snap = Snapshot()
            snap.pid = pid
            snap.app = running.localizedName ?? ""
            snap.bundle = running.bundleIdentifier ?? ""
            result.snap = snap
        }
        result.contextState = .denied
        done()
    }
    guard CGPreflightScreenCaptureAccess() else {
        result.shotState = .denied
        done()
        return
    }
    // The bar takes its screenshot with the region picker; only a scripted submit captures the window itself.
    guard windowShot else {
        result.shotState = .unavailable
        done()
        return
    }
    guard let window = frontWindowID(pid: pid) else {
        result.shotState = .unavailable
        done()
        return
    }
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("dsh-launcher-\(UUID().uuidString).png")
    DispatchQueue.global(qos: .userInitiated).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window), path]
        try? task.run()
        task.waitUntilExit()
        let ok = FileManager.default.fileExists(atPath: path)
        DispatchQueue.main.async {
            result.shotPath = ok ? path : nil
            result.shotState = ok ? .ready : .unavailable
            done()
        }
    }
}

/// Runs the system region picker. Calls back on the main thread with the PNG's path, or nil when cancelled.
func pickRegion(done: @escaping (String?) -> Void) {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("dsh-launcher-\(UUID().uuidString).png")
    DispatchQueue.global(qos: .userInitiated).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", "-o", path]
        try? task.run()
        task.waitUntilExit()
        let ok = FileManager.default.fileExists(atPath: path)
        DispatchQueue.main.async { done(ok ? path : nil) }
    }
}

/// The whole of one screen, no picker. `frame` is that screen's frame in AppKit coordinates.
func captureScreen(_ frame: NSRect, done: @escaping (String?) -> Void) {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("dsh-launcher-\(UUID().uuidString).png")
    // screencapture measures from the top left of the main screen; AppKit from its bottom left.
    let mainHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
    let rect = "\(Int(frame.minX)),\(Int(mainHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    DispatchQueue.global(qos: .userInitiated).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", rect, path]
        try? task.run()
        task.waitUntilExit()
        let ok = FileManager.default.fileExists(atPath: path)
        DispatchQueue.main.async { done(ok ? path : nil) }
    }
}

func contextPayload(_ snap: Snapshot) -> [String: Any] {
    ["app": snap.app, "bundle": snap.bundle, "title": snap.title, "url": snap.url,
     "selected": snap.selected, "text": snap.text, "truncated": snap.truncated]
}

final class Launcher: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let panel: Panel
    let prompt = PromptView()
    /// What became of the last send, when there is something to say: it failed, or it went while the bar stayed.
    let statusLabel = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    let send = NSButton(title: "", target: nil, action: nil)
    var promptHeight: NSLayoutConstraint!
    var shotChip: BarButton!
    var contextChip: BarButton!
    var newChip: BarButton!
    var lastChip: BarButton!
    var workspaceButton: BarButton!
    var modelButton: BarButton!
    var thumbnail: Thumbnail!
    var contextTag: BarButton!
    var attachments: NSStackView!
    let createMoreSwitch = MiniSwitch()
    let openMainSwitch = MiniSwitch()
    var switchLabels: [(NSTextField, MiniSwitch)] = []
    var previousApp: NSRunningApplication?
    /// Sent lines the host has not answered yet, oldest first.
    var inFlight: [String] = []
    var current = Capture()
    /// A capture is under way: the bar is out of the picture meanwhile and the hotkeys wait.
    var picking = false
    /// Until then, losing the keyboard is the system shuffling windows, not the user clicking away.
    var graceUntil = Date.distantPast

    var prefs = Prefs()
    var workspaces: [(id: String, title: String)] = []
    var models: [(provider: String, id: String, name: String, group: String)] = []
    var hasLast = false
    /// What a new session gets when the user has not picked: the host's most recent workspace and default model.
    var defaultWorkspaceId = ""
    var defaultModel = ""
    /// What the two pickers show and a submit sends: the user's pick, or else the default.
    var shownWorkspaceId = ""
    var shownModel = ""

    static let width: CGFloat = 720
    static let lineHeight: CGFloat = 26
    static let linePadding: CGFloat = 16
    static let footHeight: CGFloat = 40

    init(placeholder: String) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Launcher.width, height: Launcher.linePadding * 2 + Launcher.lineHeight + Launcher.footHeight),
                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        shotChip = BarButton(icon: "camera", target: self, action: #selector(toggleShot))
        contextChip = BarButton(icon: "text.alignleft", target: self, action: #selector(toggleContext))
        shotChip.toolTip = "Attach a screenshot of this screen"
        newChip = BarButton(title: "New", target: self, action: #selector(chooseNew))
        lastChip = BarButton(title: "Last", target: self, action: #selector(chooseLast))
        newChip.toolTip = "Start a new session"
        lastChip.toolTip = "Continue the most recent session"
        workspaceButton = BarButton(icon: "folder", chevron: true, target: self, action: #selector(showWorkspaces))
        modelButton = BarButton(icon: "sparkle", chevron: true, target: self, action: #selector(showModels))
        thumbnail = Thumbnail(target: self, action: #selector(toggleShot))
        contextTag = BarButton(icon: "text.alignleft", target: self, action: #selector(toggleContext))
        contextTag.isTag = true
        contextTag.toolTip = "Remove the window text (⌘2)"
        panel.onChipKey = { [weak self] index in
            if index == 0 { self?.toggleShot() } else { self?.toggleContext() }
        }
        panel.onSend = { [weak self] in self?.submit() }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        // A mask image, not a layer corner radius: the layer clips the material but the window keeps its square
        // corners, which show as light tips against the shadow.
        let radius: CGFloat = 16
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        panel.contentView = effect
        // Glass with a wash over it: thin enough that the blur behind still reads, thick enough that the bar keeps
        // its own tone over a bright page. A hairline for an edge.
        let wash = NSBox()
        wash.boxType = .custom
        wash.cornerRadius = radius
        wash.borderWidth = 1
        wash.borderColor = NSColor.labelColor.withAlphaComponent(0.1)
        wash.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.68)
        wash.frame = effect.bounds
        wash.autoresizingMask = [.width, .height]
        effect.addSubview(wash)

        // The line: the prompt and the one button. It starts as a single line and grows with what is typed.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        prompt.placeholder = placeholder
        prompt.delegate = self
        prompt.drawsBackground = false
        prompt.isRichText = false
        prompt.font = .systemFont(ofSize: 17)
        prompt.textColor = .labelColor
        prompt.insertionPointColor = .labelColor
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.isAutomaticSpellingCorrectionEnabled = false
        prompt.isVerticallyResizable = true
        prompt.autoresizingMask = [.width]
        prompt.textContainerInset = NSSize(width: 0, height: 2)
        prompt.textContainer?.widthTracksTextView = true
        prompt.onChange = { [weak self] in self?.textChanged() }
        scroll.documentView = prompt

        // Round, and lit only once there is something to send.
        send.target = self
        send.action = #selector(sendClicked)
        send.isBordered = false
        send.wantsLayer = true
        send.layer?.cornerRadius = 15
        send.image = symbol("arrow.up", size: 12.5, weight: .bold)
        send.imagePosition = .imageOnly
        send.toolTip = "Send (Return)"
        send.translatesAutoresizingMaskIntoConstraints = false

        // What is attached, between the line and the foot.
        attachments = NSStackView(views: [thumbnail, contextTag])
        attachments.orientation = .horizontal
        attachments.spacing = 8
        attachments.alignment = .bottom
        attachments.translatesAutoresizingMaskIntoConstraints = false

        // The foot: the options, kept out of the line being typed. A shade darker, under a hairline.
        let foot = NSBox()
        foot.boxType = .custom
        foot.borderWidth = 0
        foot.fillColor = NSColor.black.withAlphaComponent(0.1)
        foot.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = NSColor.labelColor.withAlphaComponent(0.08)
        separator.translatesAutoresizingMaskIntoConstraints = false

        func switchRow(_ title: String, _ control: MiniSwitch) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11.5)
            control.target = self
            control.action = #selector(switchChanged)
            switchLabels.append((label, control))
            let row = NSStackView(views: [label, control])
            row.spacing = 7
            return row
        }
        let switches = NSStackView(views: [switchRow("Create more", createMoreSwitch), switchRow("Open DSH", openMainSwitch)])
        switches.spacing = 16
        switches.setContentHuggingPriority(.required, for: .horizontal)
        switches.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        statusLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let segment = NSStackView(views: [newChip, lastChip])
        segment.spacing = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [shotChip, contextChip, segment, workspaceButton, modelButton, spacer, statusLabel, switches])
        bottom.orientation = .horizontal
        bottom.spacing = 4
        bottom.alignment = .centerY
        bottom.setCustomSpacing(2, after: shotChip)
        bottom.setCustomSpacing(8, after: contextChip)
        bottom.setCustomSpacing(8, after: segment)
        bottom.setCustomSpacing(14, after: statusLabel)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        for view in [foot, separator, scroll, send, attachments, bottom] as [NSView] { effect.addSubview(view) }
        promptHeight = scroll.heightAnchor.constraint(equalToConstant: Launcher.lineHeight)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: Launcher.linePadding),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15),
            scroll.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -12),
            promptHeight,
            send.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            send.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            send.widthAnchor.constraint(equalToConstant: 30),
            send.heightAnchor.constraint(equalToConstant: 30),
            attachments.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            attachments.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -20),
            attachments.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),
            contextTag.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            foot.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            foot.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            foot.heightAnchor.constraint(equalToConstant: Launcher.footHeight),
            separator.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: foot.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            bottom.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            bottom.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
            workspaceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            modelButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        applyOptions()
        refreshChips()
        paintSend()
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.popupOpen = true }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.popupOpen = false
            self.graceUntil = Date().addingTimeInterval(0.4)
            if self.panel.isVisible { self.panel.makeKey() }
        }
    }

    /// Shows a line in the foot: what became of the last send. Empty takes it away again.
    func status(_ text: String, failed: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = text.isEmpty
    }

    func paintSend() {
        let ready = !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            send.layer?.backgroundColor = (ready ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.08)).cgColor
        }
        send.contentTintColor = ready ? .white : .secondaryLabelColor
    }

    func textChanged() {
        paintSend()
        // Typing again is the answer to a failure note.
        if !statusLabel.isHidden { status("") }
        resize()
    }

    /// Fits the bar to its contents, growing downwards from a fixed top edge: up to six lines of prompt, then
    /// the attachments when there are any, then the foot.
    func resize() {
        var text = Launcher.lineHeight
        if let layout = prompt.layoutManager, let container = prompt.textContainer {
            layout.ensureLayout(for: container)
            text = min(Launcher.lineHeight * 6, max(Launcher.lineHeight, ceil(layout.usedRect(for: container).height) + 4))
        }
        promptHeight.constant = text
        let height = Launcher.linePadding * 2 + text + (attachments.isHidden ? 0 : 68) + Launcher.footHeight
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    var isShown: Bool { panel.isVisible }

    // MARK: Where the prompt goes

    /// The host's lists and remembered choices, or a change to them: redraw every control from `prefs`.
    func applyOptions() {
        createMoreSwitch.state = prefs.createMore ? .on : .off
        openMainSwitch.state = prefs.openMain ? .on : .off
        for (label, control) in switchLabels { label.textColor = control.state == .on ? .labelColor : .secondaryLabelColor }
        if prefs.target == "last" && !hasLast { prefs.target = "new" }
        let last = prefs.target == "last"
        newChip.isOn = !last
        lastChip.isOn = last
        lastChip.isEnabled = hasLast

        // Each picker names what will really be used: the user's pick, or else the host's default.
        let workspace = workspaces.first { $0.id == prefs.workspaceId } ?? workspaces.first { $0.id == defaultWorkspaceId } ?? workspaces.first
        shownWorkspaceId = workspace?.id ?? ""
        workspaceButton.title = workspace?.title ?? "No workspace"
        let key = { (model: (provider: String, id: String, name: String, group: String)) in "\(model.provider)\n\(model.id)" }
        let model = models.first { !prefs.modelProvider.isEmpty && key($0) == "\(prefs.modelProvider)\n\(prefs.modelId)" }
            ?? models.first { key($0) == defaultModel } ?? models.first
        shownModel = model.map(key) ?? ""
        // The provider is part of the name once there is more than one to choose from.
        let severalGroups = Set(models.map { $0.group }).count > 1
        modelButton.title = model.map { severalGroups ? "\($0.group) · \($0.name)" : $0.name } ?? "No model"
        // Continuing a session keeps its folder and its model.
        workspaceButton.isEnabled = !last && !workspaces.isEmpty
        modelButton.isEnabled = !last && !models.isEmpty
    }

    func prefsChanged() {
        applyOptions()
        emit(["prefs": prefs.json])
    }

    @objc func chooseNew() { prefs.target = "new"; prefsChanged() }
    @objc func chooseLast() { if hasLast { prefs.target = "last"; prefsChanged() } }

    @objc func switchChanged() {
        prefs.createMore = createMoreSwitch.state == .on
        prefs.openMain = openMainSwitch.state == .on
        prefsChanged()
        panel.makeFirstResponder(prompt)
    }

    func popUp(_ menu: NSMenu, from button: BarButton) {
        menu.font = .systemFont(ofSize: 13)
        // Above the bar, like a menu that opens out of its button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
        panel.makeFirstResponder(prompt)
    }

    @objc func showWorkspaces() {
        let menu = NSMenu()
        for workspace in workspaces {
            let item = NSMenuItem(title: workspace.title, action: #selector(pickWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.id
            item.state = workspace.id == shownWorkspaceId ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: workspaceButton)
    }

    @objc func pickWorkspace(_ item: NSMenuItem) {
        prefs.workspaceId = item.representedObject as? String ?? ""
        prefsChanged()
    }

    @objc func showModels() {
        let menu = NSMenu()
        var group = ""
        for model in models {
            if model.group != group {
                if !group.isEmpty { menu.addItem(.separator()) }
                group = model.group
                menu.addItem(.sectionHeader(title: group))
            }
            let item = NSMenuItem(title: model.name, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(model.provider)\n\(model.id)"
            item.state = "\(model.provider)\n\(model.id)" == shownModel ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, from: modelButton)
    }

    @objc func pickModel(_ item: NSMenuItem) {
        let model = (item.representedObject as? String ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
        guard model.count == 2 else { return }
        prefs.modelProvider = model[0]
        prefs.modelId = model[1]
        prefsChanged()
    }

    // MARK: Opening

    /// A hotkey press: the plain one opens the bar, the context one picks a screenshot first.
    func open(withContext: Bool) {
        guard !picking else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        current.discardShot()
        current = Capture()
        shotChip.isOn = false
        // The region the user is about to pick is the attachment; the window text stays one ⌘2 away.
        contextChip.isOn = false
        let token = current
        // The window's text is read now, while that window is still the one in front.
        capture(pid: captureTarget(), into: token, windowShot: false) { [weak self] in
            guard let self = self, self.current === token else { return }
            self.refreshChips()
        }
        guard withContext, CGPreflightScreenCaptureAccess() else {
            present()
            return
        }
        picking = true
        pickRegion { [weak self] path in
            guard let self = self else { return }
            self.picking = false
            // Esc in the picker cancels the whole thing: nothing opens.
            guard let path = path, self.current === token else {
                if let path = path { try? FileManager.default.removeItem(atPath: path) }
                return
            }
            self.attach(path)
            self.present()
        }
    }

    func attach(_ path: String) {
        current.discardShot()
        current.shotPath = path
        current.shotState = .ready
        shotChip.isOn = true
    }

    /// Puts the bar on screen, sized for whether it carries a picture.
    func present() {
        refreshChips()
        paintSend()
        // The screen under the pointer, so the bar opens where the user is working.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.76 - size.height))
        }
        // Ask to become the active app, and take the keyboard either way: macOS does not always let a background
        // process activate (after the region picker, for one), and a non-activating panel can be key without it.
        graceUntil = Date().addingTimeInterval(0.6)
        NSApp.activate(ignoringOtherApps: true)
        // It arrives rather than appears: a short fade, every time it is summoned.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(prompt)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        emit(["shown": true, "context": contextChip.isOn, "screenshot": current.shotPath != nil])
        // Where the keyboard really went, once the window server has settled; the host logs it when it is not here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            emit(["focus": ["key": self.panel.isKeyWindow, "active": NSApp.isActive]])
        }
    }

    func refreshChips() {
        let attached = current.shotPath != nil
        shotChip.isOn = attached
        shotChip.toolTip = current.shotState == .denied ? "Allow Screen Recording to attach a screenshot"
            : (attached ? "Remove the screenshot (⌘1)" : "Attach a screenshot of this screen (⌘1)")
        let snap = current.snap
        let name = [snap?.app ?? "", snap?.title ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
        switch current.contextState {
        case .pending, .ready: contextChip.toolTip = "Attach the text of \(name.isEmpty ? "the window you were in" : name) (⌘2)"
        case .denied: contextChip.toolTip = "Allow Accessibility to attach the window's text"
        case .unavailable: contextChip.toolTip = "No window to read"
        }
        contextChip.isEnabled = current.contextState != .unavailable
        let withText = contextChip.isOn && current.contextState == .ready

        thumbnail.image = current.shotPath.flatMap { NSImage(contentsOfFile: $0) }
        thumbnail.isHidden = !attached
        contextTag.title = name.isEmpty ? "Window text" : name
        contextTag.isHidden = !withText
        attachments.isHidden = !attached && !withText
        resize()
    }

    @objc func toggleShot() {
        if current.shotState == .denied || !CGPreflightScreenCaptureAccess() {
            // Opens the system prompt the first time, and is a no-op afterwards; the grant applies from the next launch.
            CGRequestScreenCaptureAccess()
            return
        }
        guard !picking else { return }
        if current.shotPath != nil {
            current.discardShot()
            current.shotState = .unavailable
            refreshChips()
            return
        }
        // The whole screen the bar is on, at once. The bar turns invisible for the shot instead of closing, so it
        // is not in the picture and keeps the keyboard.
        guard let frame = (panel.screen ?? NSScreen.main)?.frame else { return }
        let token = current
        picking = true
        panel.alphaValue = 0
        captureScreen(frame) { [weak self] path in
            guard let self = self else { return }
            self.picking = false
            self.panel.alphaValue = 1
            guard self.current === token, self.panel.isVisible else {
                if let path = path { try? FileManager.default.removeItem(atPath: path) }
                return
            }
            if let path = path { self.attach(path) }
            self.refreshChips()
        }
    }

    @objc func toggleContext() {
        if current.contextState == .denied {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        guard current.contextState != .unavailable else { return }
        contextChip.isOn.toggle()
        refreshChips()
    }

    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        current.discardShot()
        if restoreFocus { previousApp?.activate() }
    }

    func toggle(withContext: Bool) { if isShown { hide(restoreFocus: true) } else { open(withContext: withContext) } }

    // MARK: Sending

    // Return sends, Shift-Return breaks the line, Tab switches between a new session and the last one.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // A Return that commits an input-method composition is not a submit.
            if textView.hasMarkedText() { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            submit()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            if prefs.target == "last" { chooseNew() } else { chooseLast() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(restoreFocus: true)
            return true
        default:
            return false
        }
    }

    @objc func sendClicked() { submit() }

    func submit() {
        let text = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inFlight.append(text)
        var submit: [String: Any] = ["text": text, "target": prefs.target, "openMain": prefs.openMain]
        if prefs.target == "new" {
            // What the pickers show is what is sent, picked or not.
            if !shownWorkspaceId.isEmpty { submit["workspaceId"] = shownWorkspaceId }
            let model = shownModel.split(separator: "\n", maxSplits: 1).map(String.init)
            if model.count == 2 { submit["model"] = ["provider": model[0], "id": model[1]] }
        }
        if let path = current.shotPath {
            submit["screenshot"] = path
            current.shotPath = nil // the host owns the file now
        }
        if contextChip.isOn, current.contextState == .ready, let snap = current.snap { submit["context"] = contextPayload(snap) }
        emit(["submit": submit])
        // The Return is its own receipt: the bar does not wait for the round trip. It leaves at once, or with
        // "Create more" it is empty and ready for the next line. Only a failure speaks up afterwards.
        prompt.string = ""
        current.shotState = .unavailable
        contextChip.isOn = false
        status("")
        if prefs.createMore {
            refreshChips()
            textChanged()
            // The main app coming forward must not close the bar under it.
            graceUntil = Date().addingTimeInterval(1.5)
        } else {
            hide(restoreFocus: !prefs.openMain)
        }
        // A host that never answers counts as a failure too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.inFlight.contains(text) == true { self?.finish(ok: false, message: "DSH did not answer") }
        }
    }

    /// The host's verdict on the oldest send still in flight. Success is silent unless the bar stayed open; a
    /// failure brings the bar back with the line in it.
    func finish(ok: Bool, message: String) {
        guard !inFlight.isEmpty else { return }
        let text = inFlight.removeFirst()
        if ok {
            guard panel.isVisible, prefs.createMore else { return }
            status(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.statusLabel.stringValue == message { self?.status("") }
            }
            return
        }
        // Unless the user is already typing the next one, which wins.
        if prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prompt.string = text }
        if !panel.isVisible { present() }
        paintSend()
        resize()
        status(message, failed: true)
        panel.makeFirstResponder(prompt)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming the active app shuffles the key window once right after the bar opens; that is not the user
        // clicking away, so take the keyboard back instead of closing.
        if Date() < graceUntil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.panel.isVisible else { return }
                self.panel.makeKey()
                self.panel.makeFirstResponder(self.prompt)
            }
            return
        }
        // A menu of one of the pop-ups takes the keyboard while it is open.
        if !picking, NSApp.modalWindow == nil, !popupOpen { hide(restoreFocus: false) }
    }

    var popupOpen = false
}

/// A submit that never showed the bar: capture what was asked for, then emit it like a typed one.
func scriptedSubmit(text: String, screenshot: Bool, context: Bool, pid: pid_t?, options: [String: Any]) {
    // `options` are the choices the bar would have made: target, workspaceId, model, openMain.
    guard screenshot || context else {
        emit(["submit": options.merging(["text": text]) { _, new in new }])
        return
    }
    let result = Capture()
    var emitted = false
    capture(pid: pid ?? captureTarget(), into: result, windowShot: screenshot) {
        guard !emitted, result.shotState != .pending, result.contextState != .pending else { return }
        emitted = true
        var submit: [String: Any] = options.merging(["text": text]) { _, new in new }
        if screenshot, let path = result.shotPath { submit["screenshot"] = path } else { result.discardShot() }
        if context, result.contextState == .ready, let snap = result.snap { submit["context"] = contextPayload(snap) }
        emit(["submit": submit])
    }
}

/// The parent chain of this process, nearest first.
func ancestorPids() -> [pid_t] {
    var pids: [pid_t] = []
    var pid = getppid()
    while pid > 1 && pids.count < 16 {
        pids.append(pid)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return pids
}

func activateAncestor(prefixes: [String]) -> Bool {
    for pid in ancestorPids() {
        guard let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleIdentifier else { continue }
        if prefixes.contains(where: { bundle.hasPrefix($0) }) { return app.activate() }
    }
    return false
}

var hotkeySpec = "shift+cmd+space"
var contextHotkeySpec = ""
var placeholder = "Ask DSH anything…"
var args = Array(CommandLine.arguments.dropFirst())
while args.count >= 2 {
    switch args[0] {
    case "--hotkey": hotkeySpec = args[1]
    case "--context-hotkey": contextHotkeySpec = args[1]
    case "--placeholder": placeholder = args[1]
    case "--max-chars": captureOptions.maxChars = max(500, Int(args[1]) ?? 6000)
    case "--ignore-bundle": captureOptions.ignoreBundles.insert(args[1])
    case "--exclude-bundle": captureOptions.excludeBundles.insert(args[1])
    default: break
    }
    args.removeFirst(2)
}

guard let (keyCode, modifiers) = parseHotkey(hotkeySpec) else {
    emit(["error": "bad_hotkey", "hotkey": hotkeySpec])
    exit(2)
}
var contextKey: (UInt32, UInt32)?
if !contextHotkeySpec.isEmpty {
    guard let parsed = parseHotkey(contextHotkeySpec) else {
        emit(["error": "bad_hotkey", "hotkey": contextHotkeySpec])
        exit(2)
    }
    contextKey = parsed
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let launcher = Launcher(placeholder: placeholder)

// Hotkey id 1 opens the plain bar, id 2 the bar with the current window attached.
var handler: EventHandlerRef?
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    let withContext = id.id == 2
    DispatchQueue.main.async { launcher.toggle(withContext: withContext) }
    return noErr
}, 1, &spec, nil, &handler)

var hotkeyRef: EventHotKeyRef?
let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x44534851), id: 1),
                                 GetApplicationEventTarget(), 0, &hotkeyRef)
guard status == noErr else {
    emit(["error": "hotkey_unavailable", "hotkey": hotkeySpec, "status": Int(status)])
    exit(2)
}
var contextHotkeyRef: EventHotKeyRef?
var contextRegistered = false
if let (code, mods) = contextKey {
    // The plain hotkey is the one that must work; a taken context hotkey is reported and skipped.
    contextRegistered = RegisterEventHotKey(code, mods, EventHotKeyID(signature: OSType(0x44534851), id: 2),
                                            GetApplicationEventTarget(), 0, &contextHotkeyRef) == noErr
    if !contextRegistered { emit(["warn": "context_hotkey_unavailable", "hotkey": contextHotkeySpec]) }
}

Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        DispatchQueue.main.async {
            switch req["op"] as? String {
            case "show": if !launcher.isShown { launcher.open(withContext: req["context"] as? Bool ?? false) }
            case "hide": launcher.hide(restoreFocus: true)
            case "toggle": launcher.toggle(withContext: req["context"] as? Bool ?? false)
            case "done": launcher.finish(ok: true, message: req["message"] as? String ?? "Sent")
            case "failed": launcher.finish(ok: false, message: req["message"] as? String ?? "Failed")
            case "submit":
                if let text = (req["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    scriptedSubmit(text: text, screenshot: req["screenshot"] as? Bool ?? false, context: req["context"] as? Bool ?? false,
                                   pid: (req["pid"] as? Int).map { pid_t($0) }, options: req["options"] as? [String: Any] ?? [:])
                }
            case "options":
                // The host's workspaces, models and remembered choices; sent at start and each time the bar opens.
                launcher.workspaces = ((req["workspaces"] as? [[String: Any]]) ?? []).compactMap {
                    guard let id = $0["id"] as? String, let title = $0["title"] as? String else { return nil }
                    return (id: id, title: title)
                }
                launcher.models = ((req["models"] as? [[String: Any]]) ?? []).compactMap {
                    guard let provider = $0["provider"] as? String, let id = $0["id"] as? String else { return nil }
                    return (provider: provider, id: id, name: $0["name"] as? String ?? id, group: $0["group"] as? String ?? provider)
                }
                launcher.hasLast = req["hasLast"] as? Bool ?? false
                launcher.defaultWorkspaceId = req["defaultWorkspaceId"] as? String ?? ""
                if let model = req["defaultModel"] as? [String: Any], let provider = model["provider"] as? String, let id = model["id"] as? String {
                    launcher.defaultModel = "\(provider)\n\(id)"
                }
                if let prefs = req["prefs"] as? [String: Any] { launcher.prefs.merge(prefs) }
                launcher.applyOptions()
            case "activate":
                emit(["activated": activateAncestor(prefixes: (req["bundlePrefixes"] as? [String]) ?? [])])
            default: break
            }
        }
    }
    exit(0)
}

var ready: [String: Any] = ["ready": true, "hotkey": hotkeySpec, "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()]
if contextRegistered { ready["contextHotkey"] = contextHotkeySpec }
emit(ready)
app.run()
