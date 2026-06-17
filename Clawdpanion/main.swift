import AppKit

// Claw'd menubar mascot. Shows a static Claw'd when idle and a looping
// "typing" animation while a Claude Code session is active. Activity is
// signalled by marker files under ~/.claude/claw-mascot/{active,attention,done}
// that Claude Code hooks create/remove.
//
// Two display modes (persisted, toggled from the menu):
//   • single  — one menubar Claw'd showing the aggregate state across sessions
//   • per-session — one Claw'd per live Claude session, each animating to its
//     own state and left-click-jumping to its own Terminal tab.

let kBaseDir = ("~/.claude/claw-mascot" as NSString).expandingTildeInPath
let kActiveDir = kBaseDir + "/active"
let kDoneDir = kBaseDir + "/done"
let kAttentionDir = kBaseDir + "/attention"
let kDoneTransientDuration: TimeInterval = 5.0  // how long "done" pose holds before fading
let kSessionsDir = kBaseDir + "/sessions"
let kFocusScript = kBaseDir + "/focus.scpt"
let kStaleSeconds: TimeInterval = 8 * 60 * 60   // ignore/clean markers older than this
let kSessionStaleSeconds: TimeInterval = 6 * 60 * 60  // drop sessions idle this long (likely closed)
let kFPS = 7.0
// Idle blink: every few seconds Claw'd shuts its eyes for a frame or two so it
// looks alive while sitting still. Interval is randomised per blink.
let kIdleBlinkMin: TimeInterval = 3.5
let kIdleBlinkMax: TimeInterval = 8.0
let kBlinkTicks = 1            // frames the closed-eye pose holds (~1/kFPS each)
let kMonoDefaultsKey = "ClawdMono"
let kMultiDefaultsKey = "ClawdMultiPerSession"

let kListScript = kBaseDir + "/list_sessions.py"

enum MascotState { case idle, coding, attention, done }

struct SessionInfo {
    let id: String
    let label: String   // project folder name
    let status: String  // "coding" | "idle"
    let tty: String
    var coding: Bool { status == "coding" }
}

// Menubar icon size (points). Art canvas is 16x11 (12x9 body + transparent
// padding), so keep that aspect ratio. ICON_H is sized so the body inside the
// padding stays ~the same visual size as the unpadded 11pt version.
let ICON_H: CGFloat = 11
let ICON_W: CGFloat = ICON_H * 16.0 / 11.0

// One menubar icon + its own animation state. `sid == nil` is the aggregate
// mascot used in single mode (and as a placeholder in per-session mode when
// there are no sessions, so the menu stays reachable).
final class Mascot {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sid: String?
    var state: MascotState = .idle
    var frameIndex = 0
    var animCounter = 0
    var doneActiveAt: Date? = nil   // when the transient "done" pose started
    var nextBlinkAt: Date = .distantFuture  // when the next idle blink should start
    var blinkTicks = 0              // >0 while the idle blink (closed eyes) is showing
    // Each mascot owns its menu, attached to its status item so macOS opens it
    // natively on any click. The delegate rebuilds it fresh each time it opens.
    let menu = NSMenu()

    func dispose() { NSStatusBar.system.removeStatusItem(statusItem) }
}

final class MascotController: NSObject, NSMenuDelegate {
    // Two themes: full-color orange, and mono (template/monochrome) with eye-holes.
    var colorIdle = NSImage(), monoIdle = NSImage()
    var colorIdleBlink = NSImage(), monoIdleBlink = NSImage()   // idle, eyes closed
    var colorTyping: [NSImage] = [], monoTyping: [NSImage] = []
    var colorAtt: [NSImage] = [], monoAtt: [NSImage] = []
    var colorDone: [NSImage] = [], monoDone: [NSImage] = []

    var paused = false
    var mono = UserDefaults.standard.bool(forKey: kMonoDefaultsKey)
    var multiPerSession = UserDefaults.standard.bool(forKey: kMultiDefaultsKey)
    var animTimer: Timer?
    var pollTimer: Timer?
    var scanTimer: Timer?
    var cachedSessions: [SessionInfo] = []
    var mascots: [Mascot] = []

    var idleFrame: NSImage { mono ? monoIdle : colorIdle }
    var idleBlinkFrame: NSImage { mono ? monoIdleBlink : colorIdleBlink }
    var typingFrames: [NSImage] { mono ? monoTyping : colorTyping }
    var attFrames: [NSImage] { mono ? monoAtt : colorAtt }
    var doneFrames: [NSImage] { mono ? monoDone : colorDone }

    func start() {
        loadImages()
        syncMascots()                 // build the initial icon(s)

        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / kFPS, repeats: true) { [weak self] _ in
            self?.tick()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanSessions()
        }
        poll()
        scanSessions()
    }

    // MARK: - Sessions

    // Run list_sessions.py off the main thread, cache the result, resync icons.
    func scanSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [kListScript]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            let sessions = arr.map {
                SessionInfo(id: $0["id"] as? String ?? "",
                            label: $0["label"] as? String ?? "session",
                            status: $0["status"] as? String ?? "idle",
                            tty: $0["tty"] as? String ?? "")
            }
            DispatchQueue.main.async {
                self?.cachedSessions = sessions
                self?.syncMascots()
            }
        }
    }

    // MARK: - Mascot set management

    // Reconcile the live status items with the current mode + session list.
    func syncMascots() {
        if !multiPerSession || cachedSessions.isEmpty {
            // Exactly one aggregate mascot. (In per-session mode with no
            // sessions this keeps the menu reachable.)
            if mascots.count == 1, mascots[0].sid == nil {
                refreshImage(for: mascots[0])
            } else {
                disposeAllMascots()
                mascots = [makeMascot(sid: nil)]
            }
            return
        }
        let wanted = Set(cachedSessions.map { $0.id })
        // Drop the aggregate placeholder + any sessions that went away.
        var kept: [Mascot] = []
        for m in mascots {
            if let sid = m.sid, wanted.contains(sid) { kept.append(m) } else { m.dispose() }
        }
        mascots = kept
        // Add a mascot for any new session.
        let existing = Set(mascots.compactMap { $0.sid })
        for s in cachedSessions where !existing.contains(s.id) {
            mascots.append(makeMascot(sid: s.id))
        }
        // Keep tooltips current (label can change).
        for m in mascots {
            if let s = cachedSessions.first(where: { $0.id == m.sid }) {
                m.statusItem.button?.toolTip = s.label
            }
        }
    }

    func makeMascot(sid: String?) -> Mascot {
        let m = Mascot()
        m.sid = sid
        m.menu.delegate = self           // rebuilt fresh each time it opens
        // Attach the menu directly so macOS opens it natively on any click —
        // left, right, or control-click. This is the most reliable behaviour;
        // there is no custom click handling. To jump to a session's Terminal
        // tab, click its row inside the menu (see sessionItem / focusSession).
        m.statusItem.menu = m.menu
        if let b = m.statusItem.button {
            b.imageScaling = .scaleProportionallyUpOrDown
            if let sid = sid, let s = cachedSessions.first(where: { $0.id == sid }) {
                b.toolTip = s.label
            }
        }
        m.state = stateFor(m)
        if m.state == .done { m.doneActiveAt = Date() }
        scheduleNextBlink(m)
        refreshImage(for: m)
        return m
    }

    // Pick a fresh randomised time for this mascot's next idle blink.
    func scheduleNextBlink(_ m: Mascot) {
        m.blinkTicks = 0
        m.nextBlinkAt = Date().addingTimeInterval(.random(in: kIdleBlinkMin...kIdleBlinkMax))
    }

    func disposeAllMascots() {
        for m in mascots { m.dispose() }
        mascots.removeAll()
    }

    // MARK: - Rendering

    func setImage(_ img: NSImage, for m: Mascot) {
        img.size = NSSize(width: ICON_W, height: ICON_H)
        img.isTemplate = mono
        m.statusItem.button?.image = img
    }

    // Frames for a mascot's current state (empty for idle => static).
    func frames(for m: Mascot) -> [NSImage] {
        switch m.state {
        case .attention: return attFrames
        case .coding:    return typingFrames
        case .done:      return doneFrames
        case .idle:      return []
        }
    }

    // Show the right frame for the mascot's state/theme without advancing.
    func refreshImage(for m: Mascot) {
        let f = frames(for: m)
        if !paused, !f.isEmpty {
            setImage(f[m.frameIndex % f.count], for: m)
        } else {
            setImage(idleFrame, for: m)
        }
    }

    func refreshAllImages() { for m in mascots { refreshImage(for: m) } }

    func tick() {
        guard !paused else { return }
        let now = Date()
        for m in mascots {
            let f = frames(for: m)
            if f.isEmpty { tickIdleBlink(m, now); continue }   // idle => maybe blink
            // Attention waves at half speed; done + coding play at full FPS.
            m.animCounter += 1
            if m.state == .attention && m.animCounter % 2 != 0 { continue }
            m.frameIndex = (m.frameIndex + 1) % f.count
            setImage(f[m.frameIndex], for: m)
        }
    }

    // While idle (no animation frames), shut the eyes for kBlinkTicks frames
    // every few seconds, then reopen them and schedule the next blink.
    func tickIdleBlink(_ m: Mascot, _ now: Date) {
        if m.blinkTicks > 0 {
            m.blinkTicks -= 1
            if m.blinkTicks == 0 {
                setImage(idleFrame, for: m)
                scheduleNextBlink(m)
            }
        } else if now >= m.nextBlinkAt {
            m.blinkTicks = kBlinkTicks
            setImage(idleBlinkFrame, for: m)
        }
    }

    // MARK: - State polling

    func poll() {
        for m in mascots {
            // Transient "done" — hold the celebration, then clear the marker(s)
            // it covers and drop to idle.
            if let start = m.doneActiveAt, Date().timeIntervalSince(start) >= kDoneTransientDuration {
                if let sid = m.sid { removeMarker(kDoneDir, sid) } else { clearAll(kDoneDir) }
                m.doneActiveAt = nil
                setState(.idle, for: m)
                continue
            }
            let new = stateFor(m)
            if new != m.state {
                if new == .done { m.doneActiveAt = Date() }
                setState(new, for: m)
            }
            if m.state != .done, m.doneActiveAt != nil { m.doneActiveAt = nil }
        }
    }

    func setState(_ s: MascotState, for m: Mascot) {
        m.state = s
        m.frameIndex = 0
        m.animCounter = 0
        if s == .idle { scheduleNextBlink(m) }   // start the blink clock fresh
        refreshImage(for: m)
    }

    // The state a mascot should show: aggregate (sid == nil) or one session's.
    // Priority attention > coding > done > idle: active coding keeps the typing
    // animation rather than being hijacked by a session that just finished; only
    // a session blocked waiting for you (attention) wins over coding.
    func stateFor(_ m: Mascot) -> MascotState {
        if let sid = m.sid {
            if attentionLive(sid) { return .attention }
            if markerLive(kActiveDir, sid) { return .coding }
            if markerLive(kDoneDir, sid) { return .done }
            return .idle
        }
        if anyAttentionLive() { return .attention }
        if dirHasLiveMarker(kActiveDir) { return .coding }
        if dirHasLiveMarker(kDoneDir) { return .done }
        return .idle
    }

    // Attention (waving) only counts while Claude is genuinely mid-task: the
    // attention marker must be backed by a live active marker. Claude Code fires
    // a "waiting for your input" notification ~a minute after a session goes
    // idle — by then Stop has cleared the active marker, so without this gate
    // that stray marker would leave Claw'd waving while nothing is happening.
    func attentionLive(_ sid: String) -> Bool {
        markerLive(kActiveDir, sid) && markerLive(kAttentionDir, sid)
    }

    // Aggregate: any session that is both mid-task and flagged for attention.
    func anyAttentionLive() -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: kAttentionDir) else { return false }
        return items.contains { attentionLive($0) }
    }

    // MARK: - Marker helpers

    func markerLive(_ dir: String, _ sid: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(sid)"),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) <= kStaleSeconds
    }

    func removeMarker(_ dir: String, _ sid: String) {
        try? FileManager.default.removeItem(atPath: "\(dir)/\(sid)")
    }

    func clearAll(_ dir: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in items { try? FileManager.default.removeItem(atPath: "\(dir)/\(name)") }
    }

    // True if the dir holds any non-stale marker; cleans stale ones.
    func dirHasLiveMarker(_ dir: String) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return false }
        var live = false
        let now = Date()
        for name in items {
            let path = "\(dir)/\(name)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) > kStaleSeconds {
                try? fm.removeItem(atPath: path)
            } else {
                live = true
            }
        }
        return live
    }

    // MARK: - Images

    func loadRetina(_ name: String) -> NSImage {
        let base = Bundle.main.resourcePath ?? "."
        // Frames live in a Frames/ subfolder for the Xcode build (folder
        // reference) or at the top of Resources for a plain swiftc build —
        // support both so one source file serves both builds.
        func file(_ suffix: String) -> String {
            let sub = "\(base)/Frames/\(name)\(suffix).png"
            return FileManager.default.fileExists(atPath: sub) ? sub : "\(base)/\(name)\(suffix).png"
        }
        let img = NSImage()
        if let r1 = NSImage(contentsOfFile: file(""))?.representations.first {
            img.addRepresentation(r1)
        }
        if let r2 = NSImage(contentsOfFile: file("@2x"))?.representations.first {
            r2.size = NSSize(width: r2.pixelsWide / 2, height: r2.pixelsHigh / 2)
            img.addRepresentation(r2)
        }
        img.size = NSSize(width: ICON_W, height: ICON_H)
        return img
    }

    func loadImages() {
        colorIdle = loadRetina("idle")
        monoIdle = loadRetina("mono_idle")
        colorIdleBlink = loadRetina("idle_blink")
        monoIdleBlink = loadRetina("mono_idle_blink")
        colorTyping = (0..<8).map { loadRetina("type_\($0)") }
        monoTyping = (0..<8).map { loadRetina("mono_type_\($0)") }
        colorAtt = (0..<4).map { loadRetina("att_\($0)") }
        monoAtt = (0..<4).map { loadRetina("mono_att_\($0)") }
        colorDone = (0..<4).map { loadRetina("done_\($0)") }
        monoDone = (0..<4).map { loadRetina("mono_done_\($0)") }
        if colorTyping.contains(where: { $0.representations.isEmpty }) { colorTyping = [colorIdle] }
        if monoTyping.contains(where: { $0.representations.isEmpty }) { monoTyping = [monoIdle] }
        if colorAtt.contains(where: { $0.representations.isEmpty }) { colorAtt = [colorIdle] }
        if monoAtt.contains(where: { $0.representations.isEmpty }) { monoAtt = [monoIdle] }
        if colorDone.contains(where: { $0.representations.isEmpty }) { colorDone = [colorIdle] }
        if monoDone.contains(where: { $0.representations.isEmpty }) { monoDone = [monoIdle] }
        // Missing blink art => just reuse the open-eyed idle (no blink, no crash).
        if colorIdleBlink.representations.isEmpty { colorIdleBlink = colorIdle }
        if monoIdleBlink.representations.isEmpty { monoIdleBlink = monoIdle }
    }

    // MARK: - Clicks

    // Launch the AppleScript that brings a session's Terminal tab to the front.
    // Used by the in-menu session rows (focusSession); clicking the menubar icon
    // itself only opens the menu.
    func runFocus(_ tty: String) {
        guard !tty.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [kFocusScript, tty]
        try? p.run()
    }

    // MARK: - Menu

    // Rebuild the menu every time it's about to open so the session list and
    // statuses are current. macOS calls this whenever the icon is clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        scanSessions()   // refresh cache for next open

        let sessions = cachedSessions

        // Sessions — one tappable row each (jumps to its Terminal tab), with a
        // state icon and a dimmed status line. Empty gets a quiet placeholder.
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.image = symbolImage("moon.zzz", .tertiaryLabelColor)
            menu.addItem(empty)
        } else {
            menu.addItem(.sectionHeader(title: "Sessions"))
            for s in sessions { menu.addItem(sessionItem(for: s)) }
        }

        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Display"))
        menu.addItem(toggleItem("One Claw’d per session", symbol: "rectangle.split.3x1",
                                on: multiPerSession, action: #selector(toggleMulti(_:))))
        menu.addItem(toggleItem("Monotone", symbol: "circle.lefthalf.filled",
                                on: mono, action: #selector(toggleMono(_:))))
        menu.addItem(toggleItem(paused ? "Resume animation" : "Pause animation",
                                symbol: paused ? "play.fill" : "pause.fill",
                                on: paused, action: #selector(togglePause(_:))))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Claw’d", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = symbolImage("power", .secondaryLabelColor)
        menu.addItem(quit)
    }

    // MARK: - Menu item builders

    // A session row: state icon + project name with a dimmed status subtitle.
    func sessionItem(for s: SessionInfo) -> NSMenuItem {
        let state = menuState(for: s)
        let item = NSMenuItem(title: s.label, action: #selector(focusSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s.tty
        item.toolTip = s.id
        item.image = symbolImage(stateSymbol(state), stateColor(state))

        let title = NSMutableAttributedString(string: s.label, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: "\n" + stateText(state), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title

        if s.tty.isEmpty { item.isEnabled = false }   // can't focus without a tty
        return item
    }

    // A checkable settings row with a leading glyph.
    func toggleItem(_ title: String, symbol: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.image = symbolImage(symbol, .secondaryLabelColor)
        return item
    }

    // The state to show for a session: marker-driven attention/done win, then
    // fall back to the scanner's coding/idle reading.
    func menuState(for s: SessionInfo) -> MascotState {
        if attentionLive(s.id) { return .attention }
        if markerLive(kDoneDir, s.id) { return .done }
        if s.coding || markerLive(kActiveDir, s.id) { return .coding }
        return .idle
    }

    func stateText(_ s: MascotState) -> String {
        switch s {
        case .attention: return "waiting for you"
        case .coding:    return "coding…"
        case .done:      return "done"
        case .idle:      return "idle"
        }
    }

    func stateSymbol(_ s: MascotState) -> String {
        switch s {
        case .attention: return "bell.fill"
        case .coding:    return "curlybraces"
        case .done:      return "checkmark.circle.fill"
        case .idle:      return "circle"
        }
    }

    func stateColor(_ s: MascotState) -> NSColor {
        switch s {
        case .attention: return .systemOrange
        case .coding:    return .systemOrange
        case .done:      return .systemGreen
        case .idle:      return .tertiaryLabelColor
        }
    }

    // A tinted SF Symbol sized for a menu row, or nil if the symbol is missing.
    func symbolImage(_ name: String, _ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String else { return }
        runFocus(tty)
    }

    @objc func toggleMulti(_ sender: NSMenuItem) {
        multiPerSession.toggle()
        sender.state = multiPerSession ? .on : .off
        UserDefaults.standard.set(multiPerSession, forKey: kMultiDefaultsKey)
        disposeAllMascots()   // rebuild from scratch in the new mode
        syncMascots()
    }

    @objc func toggleMono(_ sender: NSMenuItem) {
        mono.toggle()
        sender.state = mono ? .on : .off
        UserDefaults.standard.set(mono, forKey: kMonoDefaultsKey)
        refreshAllImages()
    }

    @objc func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        sender.state = paused ? .on : .off
        refreshAllImages()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon
let controller = MascotController()
controller.start()
app.run()
