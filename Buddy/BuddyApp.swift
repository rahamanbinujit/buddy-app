import SwiftUI
import AppKit
import Sparkle

@main
struct BuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: BuddyController?
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort?
    var localHotkeyMonitor: Any?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var healthReminders: HealthReminders?
    var stuckDetector: StuckDetector?
    var contextTimer: Timer?
    var waterCount: Int = 0
    var remindersEnabled: Bool = true
    var spideyPanel: SpideyMenuPanel?


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = BuddyController()
        controller?.start()

        // Skip onboarding — show character immediately
        postAuthSetup()

        // Initialize health reminders with matching animations
        healthReminders = HealthReminders(context: PersonalContext.shared)
        healthReminders?.onReminder = { [weak self] type, message in
            guard let buddy = self?.controller?.character else { return }
            let typeName: String
            switch type {
            case .water: typeName = "water"
            case .breakTime: typeName = "break"
            case .posture: typeName = "posture"
            case .movement: typeName = "movement"
            case .eyeRest: typeName = "eyeRest"
            }
            buddy.playReminder(typeName)
            buddy.showPreview(message, autoFade: true)
        }
        healthReminders?.start()

        // Initialize stuck detector with concerned animation
        stuckDetector = StuckDetector()
        stuckDetector?.onStuckDetected = { [weak self] _, message in
            guard let buddy = self?.controller?.character else { return }
            buddy.playConcerned()
            buddy.showPreview(message, autoFade: true)
        }

        // Wire focus guardian -- distraction nudges + celebration on session end
        FocusGuardian.shared.onDistraction = { [weak self] app, minutesIn in
            guard let buddy = self?.controller?.character else { return }
            let message = FocusGuardian.gentleReminder(
                task: FocusGuardian.shared.currentSession?.task ?? "Focus",
                distractionApp: app,
                minutesInSession: minutesIn
            )
            buddy.playDistraction()
            buddy.showPreview(message, autoFade: true)
        }

        FocusGuardian.shared.onSessionEnd = { [weak self] summary in
            guard let buddy = self?.controller?.character else { return }
            buddy.hideFocusProgress()

            let planned = summary.plannedDurationMinutes
            let actual = summary.totalMinutes
            let pct = planned > 0 ? Double(actual) / Double(planned) : 1.0
            let focused = summary.focusedMinutes
            let task = summary.task

            let msg: String
            if pct < 0.10 {
                // Barely started
                buddy.playConcerned()
                let options = [
                    "that was quick... \(actual) min out of \(planned). maybe try a shorter session?",
                    "\(actual) minute\(actual == 1 ? "" : "s")? we'll pretend that didn't happen.",
                    "speedrun focus session. new record? \(actual) min out of \(planned).",
                    "okay that doesn't count. \(actual) min on \"\(task)\". want to try again?",
                    "barely got started on \"\(task)\". no worries, reset and go again.",
                ]
                msg = options[Int.random(in: 0..<options.count)]
            } else if pct < 0.50 {
                // Quit early
                buddy.playReminder("break")
                let options = [
                    "\(focused) min on \"\(task)\". not bad, but you've got more in you.",
                    "halfway there! \(focused) out of \(planned) min. next time you've got this.",
                    "progress is progress. even \(focused) minutes counts.",
                    "\(focused) min focused. short session, but at least you showed up.",
                    "quit early on \"\(task)\" but \(focused) min is still something. try again later?",
                ]
                msg = options[Int.random(in: 0..<options.count)]
            } else if pct < 0.90 {
                // Almost made it
                buddy.playHappyPublic()
                let distractionSuffix = summary.distractionCount == 0 ? " zero distractions!" : " \(summary.distractionCount) distraction\(summary.distractionCount == 1 ? "" : "s")."
                let options = [
                    "so close! \(focused) out of \(planned) min on \"\(task)\". solid effort." + distractionSuffix,
                    "almost! \(focused) min of focus on \"\(task)\". that's real work." + distractionSuffix,
                    "\(focused) minutes of focus. that's not nothing. you were close to the full \(planned)." + distractionSuffix,
                    "good run on \"\(task)\". \(focused) out of \(planned) min." + distractionSuffix,
                ]
                msg = options[Int.random(in: 0..<options.count)]
            } else if pct < 1.0 {
                // Nearly complete (90-99%)
                let remaining = planned - actual
                buddy.playCelebration()
                let distractionSuffix = summary.distractionCount == 0 ? " and zero distractions!" : " with \(summary.distractionCount) distraction\(summary.distractionCount == 1 ? "" : "s")."
                let options = [
                    "that close?! you were \(remaining) min away from the full \(planned)!" + distractionSuffix,
                    "SO close. literally \(remaining) min short on \"\(task)\". still impressive." + distractionSuffix,
                    "\(focused) out of \(planned) min. you basically did it." + distractionSuffix,
                    "99% there on \"\(task)\". \(focused) min focused. count it as a win." + distractionSuffix,
                ]
                msg = options[Int.random(in: 0..<options.count)]
            } else {
                // Full completion!
                buddy.playCelebration()
                let distractionSuffix = summary.distractionCount == 0 ? " zero distractions. you're locked in." : " \(summary.distractionCount) distraction\(summary.distractionCount == 1 ? "" : "s") but you pushed through."
                let options = [
                    "crushed it! full \(planned) min on \"\(task)\"." + distractionSuffix,
                    "\(planned) minutes done. that's discipline. \"\(task)\" is moving." + distractionSuffix,
                    "perfect session on \"\(task)\". \(planned) min, start to finish." + distractionSuffix,
                    "full \(planned) min. you said you'd focus and you did." + distractionSuffix,
                    "nice. \(planned) min on \"\(task)\" complete." + distractionSuffix,
                ]
                msg = options[Int.random(in: 0..<options.count)]
            }

            buddy.showPreview(msg, autoFade: true)
        }

        // 30-second screen context observation timer
        contextTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            let app = NSWorkspace.shared.frontmostApplication
            let appName = app?.localizedName ?? "Unknown"
            // Get actual window title from the frontmost app
            let windowTitle = Self.frontmostWindowTitle() ?? appName
            let detector = self?.stuckDetector
            detector?.observe(activeApp: appName, windowTitle: windowTitle)
            FocusGuardian.shared.observe(activeApp: appName)
            PersonalContext.shared.updateWorkPatterns(activeApp: appName)
        }

        setupMenuBar()
        registerHotkey()
    }

    static func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windowList {
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
               ownerPID == pid,
               let title = window[kCGWindowName as String] as? String,
               !title.isEmpty {
                return title
            }
        }
        return nil
    }

    func postAuthSetup() {
        // Request screen recording permission once (first launch only)
        let hasAskedScreen = UserDefaults.standard.bool(forKey: "buddy.hasAskedScreenPermission")
        if !hasAskedScreen {
            UserDefaults.standard.set(true, forKey: "buddy.hasAskedScreenPermission")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                ScreenContext.requestPermission()
            }
        }

        // Welcome message from character
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let buddy = self?.controller?.character else { return }
            let greeting = "hey! i'm buddy, your desktop companion. click me or press Cmd+Shift+B to chat"
            buddy.playHappyPublic()
            buddy.showPreview(greeting, autoFade: true)
        }
    }

    func registerHotkey() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            guard type == .keyDown else { return Unmanaged.passRetained(event) }
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if flags.contains(.maskCommand) && flags.contains(.maskShift) && keyCode == 49 {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePopover() }
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func togglePopover() {
        guard let buddy = controller?.character else { return }
        if buddy.panelOpen || (buddy.popoverWindow?.isVisible ?? false) {
            buddy.closePopover()
        } else {
            buddy.openPopover()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Reserved for future URL scheme handling
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.character.session?.terminate()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        if let button = statusItem?.button {
            button.wantsLayer = true
            let iconLayer = CALayer()
            iconLayer.contents = renderMenuBarIcon().cgImage(forProposedRect: nil, context: nil, hints: nil)
            iconLayer.magnificationFilter = .nearest
            iconLayer.frame = CGRect(x: 3, y: 2, width: 24, height: 18)
            button.layer?.addSublayer(iconLayer)
            button.target = self
            button.action = #selector(statusItemClicked)
        }
    }

    @objc func statusItemClicked() {
        if let panel = spideyPanel, panel.isVisible {
            panel.close()
            spideyPanel = nil
            return
        }
        guard let button = statusItem?.button, let window = button.window else { return }
        let panel = SpideyMenuPanel(appDelegate: self)
        spideyPanel = panel
        let btnScreen = window.convertToScreen(button.frame)
        let pw = SpideyMenuPanel.panelW
        var ox = btnScreen.midX - pw / 2
        let oy = btnScreen.minY - panel.frame.height - 4
        if let screen = NSScreen.main {
            ox = max(screen.visibleFrame.minX + 4, min(ox, screen.visibleFrame.maxX - pw - 4))
        }
        panel.setFrameOrigin(NSPoint(x: ox, y: oy))
        panel.orderFront(nil)
    }


    func renderMenuBarIcon() -> NSImage {
        // Spider-Man face: red head with big white eyes
        // 0=clear, 1=red, 2=white(eyes), 3=dark red(web hint)
        let grid: [[Int]] = [
            [0,0,1,1,1,1,1,1,0,0],
            [0,1,1,1,3,3,1,1,1,0],
            [0,1,2,2,1,1,2,2,1,0],
            [0,1,2,2,1,1,2,2,1,0],
            [0,1,1,2,1,1,2,1,1,0],
            [0,0,1,1,1,1,1,1,0,0],
        ]
        let rows = grid.count
        let cols = grid[0].count
        let px = 6
        let imgW = cols * px
        let imgH = rows * px

        guard let ctx = CGContext(
            data: nil, width: imgW, height: imgH,
            bitsPerComponent: 8, bytesPerRow: imgW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: "Buddy")!
        }
        ctx.clear(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        ctx.interpolationQuality = .none
        for row in 0..<rows {
            for col in 0..<cols {
                let val = grid[row][col]
                if val == 0 { continue }
                let flippedRow = rows - 1 - row
                switch val {
                case 1: ctx.setFillColor(red: 0.88, green: 0.12, blue: 0.12, alpha: 1)
                case 2: ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
                case 3: ctx.setFillColor(red: 0.65, green: 0.08, blue: 0.08, alpha: 1)
                default: continue
                }
                ctx.fill(CGRect(x: col * px, y: flippedRow * px, width: px, height: px))
            }
        }
        guard let cgImage = ctx.makeImage() else {
            return NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: "Buddy")!
        }
        let ptH: CGFloat = 18
        let ptW = ptH * CGFloat(imgW) / CGFloat(imgH)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: ptW, height: ptH))
        return image
    }

    @objc func toggleVisibility(_ sender: NSMenuItem) {
        guard let buddy = controller?.character else { return }
        if buddy.window.isVisible {
            buddy.window.orderOut(nil)
            buddy.commentTimer?.invalidate()
            buddy.commentTimer = nil
            sender.state = .off
            sender.title = "Show Spidey"
        } else {
            buddy.window.orderFrontRegardless()
            buddy.startCommentTimer()
            sender.state = .on
            sender.title = "Hide Spidey"
        }
    }

    @objc func toggleComments(_ sender: NSMenuItem) {
        guard let buddy = controller?.character else { return }
        if buddy.commentTimer != nil {
            buddy.commentTimer?.invalidate()
            buddy.commentTimer = nil
            sender.state = .off
        } else {
            buddy.startCommentTimer()
            sender.state = .on
        }
    }

    @objc func setCommentInterval(_ sender: NSMenuItem) {
        BuddyCharacter.commentInterval = Double(sender.tag)
        if let menu = sender.menu {
            for item in menu.items where item.action == #selector(setCommentInterval(_:)) {
                item.state = item.tag == sender.tag ? .on : .off
            }
        }
        if let buddy = controller?.character, buddy.commentTimer != nil {
            buddy.startCommentTimer()
        }
    }

    @objc func toggleChatScreenContext(_ sender: NSMenuItem) {
        if !ScreenContext.hasPermission {
            ScreenContext.requestPermission()
        }
        ScreenContext.chatEnabled.toggle()
        ScreenContext.resetFailures()
        sender.state = ScreenContext.chatEnabled ? .on : .off
    }

    @objc func toggleCommentScreenContext(_ sender: NSMenuItem) {
        if !ScreenContext.hasPermission {
            ScreenContext.requestPermission()
        }
        ScreenContext.commentsEnabled.toggle()
        ScreenContext.resetFailures()
        sender.state = ScreenContext.commentsEnabled ? .on : .off
    }

    @objc func openChat() {
        togglePopover()
    }

    @objc func newChat() {
        controller?.character.clearConversation()
    }

    @objc func playEmotion(_ sender: NSMenuItem) {
        guard let buddy = controller?.character, let emoji = sender.representedObject as? String else { return }
        buddy.triggerEmotion(emoji)
    }

    @objc func startFocusSession() {
        let alert = NSAlert()
        alert.messageText = "Start Focus Session"
        alert.informativeText = "Enter a task name and duration."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        let taskField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        taskField.placeholderString = "Task name"
        container.addSubview(taskField)

        let durationPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        for mins in [15, 25, 30, 45, 60, 90, 120] {
            durationPicker.addItem(withTitle: "\(mins) minutes")
            durationPicker.lastItem?.tag = mins
        }
        durationPicker.selectItem(withTag: 25)
        container.addSubview(durationPicker)

        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            let task = taskField.stringValue.isEmpty ? "Focus" : taskField.stringValue
            let duration = durationPicker.selectedItem?.tag ?? 25
            FocusGuardian.shared.startSession(task: task, durationMinutes: duration)
            controller?.character?.showFocusProgress(task: task, durationMinutes: duration)
        }
    }

    @objc func endFocusSession() {
        _ = FocusGuardian.shared.endSession()
        controller?.character?.hideFocusProgress()
    }

    @objc func logWater() {
        healthReminders?.logWater()
        waterCount = healthReminders?.waterCount ?? (waterCount + 1)
        controller?.character?.playReminder("water")
        controller?.character?.showPreview("logged! \(waterCount)/8 glasses today", autoFade: true)
    }

    @objc func toggleReminders(_ sender: NSMenuItem) {
        remindersEnabled.toggle()
        sender.state = remindersEnabled ? .off : .on
        if remindersEnabled {
            healthReminders?.start()
        } else {
            healthReminders?.stop()
        }
    }

    @objc func blockCurrentApp() {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        guard !appName.isEmpty, appName != "Buddy" else { return }
        PersonalContext.shared.update { profile in
            if !profile.excludedApps.contains(appName) {
                profile.excludedApps.append(appName)
            }
        }
        controller?.character?.showPreview("blocked \"\(appName)\" from screenshots", autoFade: true)
    }

    @objc func unblockApp(_ sender: NSMenuItem) {
        guard let appName = sender.representedObject as? String else { return }
        PersonalContext.shared.update { profile in
            profile.excludedApps.removeAll { $0 == appName }
        }
        controller?.character?.showPreview("unblocked \"\(appName)\"", autoFade: true)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Spider-Man Sub-Item

struct SpideySubItem {
    var title:    String = ""
    var shortcut: String = ""
    var checked:  Bool   = false
    var enabled:  Bool   = true
    var isSep:    Bool   = false
    var act: (() -> Void)? = nil
    static func sep() -> SpideySubItem { SpideySubItem(isSep: true) }
}

// MARK: - Spider-Man Menu Panel

class SpideyMenuPanel: NSPanel {
    static let panelW: CGFloat = 300
    static let rowH:   CGFloat = 30
    static let sepH:   CGFloat = 9

    weak var appDelegate: AppDelegate?
    private var monitor: Any?
    var activeSubPanel: SpideySubPanel?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelW, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isMovable = false
        buildContent()
        installMonitor()
    }

    func buildContent() {
        let buddy    = appDelegate?.controller?.character
        let visible  = buddy?.window.isVisible ?? true
        let water    = appDelegate?.waterCount ?? 0
        let remind   = appDelegate?.remindersEnabled ?? true
        let blocked  = PersonalContext.shared.profile.excludedApps
        let timerOn  = buddy?.commentTimer != nil

        struct R {
            var title: String = ""; var shortcut: String = ""
            var checked: Bool = false; var enabled: Bool = true
            var sep: Bool = false
            var subItems: [SpideySubItem]? = nil; var act: (() -> Void)? = nil
        }

        var rows: [R] = []
        rows.append(R(title: visible ? "Hide Spidey" : "Show Spidey", shortcut: "⌘C", checked: visible,
                      act: { [weak self] in self?.appDelegate.map { d in d.toggleVisibility(NSMenuItem()) } }))
        rows.append(R(sep: true))
        rows.append(R(title: "Chat",            subItems: chatItems()))
        rows.append(R(title: "Screen Comments", subItems: commentsItems(timerOn: timerOn)))
        rows.append(R(title: "Emotions",        subItems: emotionItems()))
        rows.append(R(title: "Privacy",         subItems: privacyItems(blocked: blocked)))
        rows.append(R(title: "Focus",           subItems: focusItems()))
        rows.append(R(title: "Health",          subItems: healthItems(water: water, remind: remind)))
        rows.append(R(sep: true))
        rows.append(R(title: "Settings",
                      act: { SettingsWindow.show() }))
        rows.append(R(sep: true))
        rows.append(R(title: "Check for Updates...",
                      act: { [weak self] in self?.appDelegate?.updaterController.checkForUpdates(nil) }))
        rows.append(R(sep: true))
        rows.append(R(title: "Quit", shortcut: "⌘Q", act: { NSApp.terminate(nil) }))

        let totalH = rows.reduce(CGFloat(0)) { $0 + ($1.sep ? Self.sepH : Self.rowH) } + 12
        let W = Self.panelW

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: W, height: totalH))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(red: 0.075, green: 0.075, blue: 0.118, alpha: 0.98).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1).cgColor

        var y = totalH - 6
        for r in rows {
            if r.sep {
                y -= Self.sepH
                let line = NSView(frame: NSRect(x: 8, y: y + Self.sepH / 2, width: W - 16, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor(red: 0.18, green: 0.18, blue: 0.26, alpha: 1).cgColor
                bg.addSubview(line)
            } else {
                y -= Self.rowH
                let row = SpideyMenuRow(
                    frame: NSRect(x: 6, y: y, width: W - 12, height: Self.rowH),
                    title: r.title, shortcut: r.shortcut, checked: r.checked,
                    enabled: r.enabled, subItems: r.subItems, act: r.act, panel: self
                )
                bg.addSubview(row)
            }
        }

        contentView = bg
        setContentSize(NSSize(width: W, height: totalH))
    }

    // MARK: Sub-item builders

    private func chatItems() -> [SpideySubItem] { [
        SpideySubItem(title: "Open",     shortcut: "⌘⇧Space", act: { [weak self] in self?.appDelegate?.openChat() }),
        SpideySubItem(title: "New Chat", shortcut: "⌘N",      act: { [weak self] in self?.appDelegate?.newChat() }),
        .sep(),
        SpideySubItem(title: "Screen Context", checked: ScreenContext.chatEnabled,
                      act: { [weak self] in self?.appDelegate?.toggleChatScreenContext(NSMenuItem()) })
    ] }

    private func commentsItems(timerOn: Bool) -> [SpideySubItem] {
        var items: [SpideySubItem] = [
            SpideySubItem(title: "Enabled", checked: timerOn,
                          act: { [weak self] in self?.appDelegate?.toggleComments(NSMenuItem()) }),
            .sep(),
            SpideySubItem(title: "Screen Context", checked: ScreenContext.commentsEnabled,
                          act: { [weak self] in self?.appDelegate?.toggleCommentScreenContext(NSMenuItem()) }),
            .sep()
        ]
        for secs in [5, 10, 15, 30, 60, 120, 300] {
            let label = secs < 60 ? "\(secs)s" : "\(secs/60)m"
            let s = secs
            items.append(SpideySubItem(title: "Every \(label)",
                                       checked: Int(BuddyCharacter.commentInterval) == secs,
                                       act: { [weak self] in
                let it = NSMenuItem(); it.tag = s
                self?.appDelegate?.setCommentInterval(it)
            }))
        }
        return items
    }

    private func emotionItems() -> [SpideySubItem] {
        [("😄 Happy","😄"),("😭 Sad","😭"),("😡 Angry","😡"),("😨 Scared","😨"),
         ("🤢 Disgust","🤢"),("😴 Sleepy","😴"),("💀 Dead","💀"),("😍 Love","😍"),
         ("🎉 Celebrate","🎉"),("🥤 Drinking","🥤"),("🧘 Stretching","🧘"),
         ("🤔 Concerned","🤔"),("🎯 Focused","🎯"),("🙌 Cheering","🙌")].map { label, id in
            SpideySubItem(title: label, act: { [weak self] in
                let it = NSMenuItem(); it.representedObject = id
                self?.appDelegate?.playEmotion(it)
            })
        }
    }

    private func privacyItems(blocked: [String]) -> [SpideySubItem] {
        var items: [SpideySubItem] = [
            SpideySubItem(title: "Block Current App", act: { [weak self] in self?.appDelegate?.blockCurrentApp() }),
            .sep()
        ]
        if blocked.isEmpty {
            items.append(SpideySubItem(title: "No apps blocked", enabled: false))
        } else {
            for app in blocked {
                let a = app
                items.append(SpideySubItem(title: "Unblock: \(app)", act: { [weak self] in
                    let it = NSMenuItem(); it.representedObject = a
                    self?.appDelegate?.unblockApp(it)
                }))
            }
        }
        return items
    }

    private func focusItems() -> [SpideySubItem] {
        let mins = FocusGuardian.shared.totalFocusMinutesToday
        let streak = FocusGuardian.shared.currentStreak
        return [
            SpideySubItem(title: "Start Focus Session...", act: { [weak self] in self?.appDelegate?.startFocusSession() }),
            SpideySubItem(title: "End Focus Session",      act: { [weak self] in self?.appDelegate?.endFocusSession() }),
            .sep(),
            SpideySubItem(title: "Today: \(mins)min | Streak: \(streak)", enabled: false)
        ]
    }

    private func healthItems(water: Int, remind: Bool) -> [SpideySubItem] { [
        SpideySubItem(title: "Log Water", act: { [weak self] in self?.appDelegate?.logWater() }),
        SpideySubItem(title: "Water today: \(water) glasses", enabled: false),
        .sep(),
        SpideySubItem(title: "Pause Reminders", checked: !remind,
                      act: { [weak self] in self?.appDelegate?.toggleReminders(NSMenuItem()) })
    ] }

    // MARK: Sub-panel switching

    func switchSubPanel(to items: [SpideySubItem]?, anchorTopLeft: NSPoint) {
        activeSubPanel?.orderOut(nil)
        activeSubPanel = nil
        guard let items = items, !items.isEmpty else { return }
        let sub = SpideySubPanel(items: items, mainPanel: self)
        activeSubPanel = sub
        var x = anchorTopLeft.x
        var y = anchorTopLeft.y - sub.frame.height
        if let screen = NSScreen.main {
            y = max(screen.visibleFrame.minY + 4, y)
            if x + SpideySubPanel.panelW > screen.visibleFrame.maxX {
                x = frame.minX - SpideySubPanel.panelW - 2
            }
        }
        sub.setFrameOrigin(NSPoint(x: x, y: y))
        sub.orderFront(nil)
    }

    // MARK: Event monitor

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            if self.frame.contains(loc) { return }
            if let sub = self.activeSubPanel, sub.frame.contains(loc) { return }
            if let button = self.appDelegate?.statusItem?.button, let win = button.window {
                if win.convertToScreen(button.frame).contains(loc) { return }
            }
            self.activeSubPanel?.orderOut(nil)
            self.activeSubPanel = nil
            self.close()
        }
    }

    override func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        activeSubPanel?.orderOut(nil)
        activeSubPanel = nil
        super.close()
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

// MARK: - Spider-Man Menu Row

class SpideyMenuRow: NSView {
    private let titleLabel    = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let checkLabel    = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private let subItems: [SpideySubItem]?
    private let act: (() -> Void)?
    private let enabled: Bool
    weak var panel: SpideyMenuPanel?

    private static let ink   = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 1.0)
    private static let dim   = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 0.4)
    private static let red   = NSColor(red: 0.878, green: 0.122, blue: 0.122, alpha: 1.0)
    private static let hover = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1.0)

    init(frame: NSRect, title: String, shortcut: String, checked: Bool, enabled: Bool,
         subItems: [SpideySubItem]?, act: (() -> Void)?, panel: SpideyMenuPanel) {
        self.subItems = subItems; self.act = act; self.enabled = enabled; self.panel = panel
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6

        checkLabel.font = .systemFont(ofSize: 13, weight: .medium)
        checkLabel.textColor = Self.red
        checkLabel.stringValue = checked ? "✓" : ""
        addSubview(checkLabel)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = enabled ? Self.ink : Self.dim
        titleLabel.stringValue = title
        addSubview(titleLabel)

        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = Self.dim
        shortcutLabel.stringValue = subItems != nil ? "›" : shortcut
        shortcutLabel.alignment = .right
        addSubview(shortcutLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height; let cy = (h - 15) / 2
        let lp: CGFloat = 8; let rp: CGFloat = 8
        let ckW: CGFloat = 20; let rtW: CGFloat = subItems != nil ? 14 : 54
        checkLabel.frame    = NSRect(x: lp,                      y: cy, width: ckW,                                      height: 15)
        titleLabel.frame    = NSRect(x: lp + ckW,                y: cy, width: bounds.width - lp*2 - ckW - rtW,         height: 15)
        shortcutLabel.frame = NSRect(x: bounds.width - rp - rtW, y: cy, width: rtW,                                     height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        layer?.backgroundColor = Self.hover.cgColor
        hoverTimer?.invalidate()
        if subItems != nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                self?.triggerSubPanel()
            }
        } else {
            panel?.switchSubPanel(to: nil, anchorTopLeft: .zero)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        layer?.backgroundColor = .clear
    }

    private func triggerSubPanel() {
        guard let items = subItems, let panelWin = window else { return }
        let topRight = convert(NSPoint(x: bounds.maxX + 2, y: bounds.maxY), to: nil)
        let screenPt = panelWin.convertToScreen(NSRect(origin: topRight, size: .zero)).origin
        panel?.switchSubPanel(to: items, anchorTopLeft: screenPt)
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        hoverTimer?.invalidate()
        layer?.backgroundColor = .clear
        if subItems != nil {
            triggerSubPanel()
        } else {
            panel?.close()
            act?()
        }
    }
}

// MARK: - Spider-Man Sub-Panel

class SpideySubPanel: NSPanel {
    static let panelW: CGFloat = 230
    static let rowH:   CGFloat = 28
    static let sepH:   CGFloat = 8

    weak var mainPanel: SpideyMenuPanel?

    init(items: [SpideySubItem], mainPanel: SpideyMenuPanel) {
        self.mainPanel = mainPanel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelW, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isMovable = false
        build(items: items)
    }

    private func build(items: [SpideySubItem]) {
        let totalH = items.reduce(CGFloat(0)) { $0 + ($1.isSep ? Self.sepH : Self.rowH) } + 12
        let W = Self.panelW
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: W, height: totalH))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(red: 0.075, green: 0.075, blue: 0.118, alpha: 0.98).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1).cgColor
        var y = totalH - 6
        for item in items {
            if item.isSep {
                y -= Self.sepH
                let line = NSView(frame: NSRect(x: 8, y: y + Self.sepH / 2, width: W - 16, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor(red: 0.18, green: 0.18, blue: 0.26, alpha: 1).cgColor
                bg.addSubview(line)
            } else {
                y -= Self.rowH
                bg.addSubview(SpideySubRow(
                    frame: NSRect(x: 6, y: y, width: W - 12, height: Self.rowH),
                    item: item, mainPanel: mainPanel
                ))
            }
        }
        contentView = bg
        setContentSize(NSSize(width: W, height: totalH))
    }
}

// MARK: - Spider-Man Sub-Row

class SpideySubRow: NSView {
    private let titleLabel    = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let checkLabel    = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private let item: SpideySubItem
    weak var mainPanel: SpideyMenuPanel?

    private static let ink   = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 1.0)
    private static let dim   = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 0.4)
    private static let red   = NSColor(red: 0.878, green: 0.122, blue: 0.122, alpha: 1.0)
    private static let hover = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1.0)

    init(frame: NSRect, item: SpideySubItem, mainPanel: SpideyMenuPanel?) {
        self.item = item; self.mainPanel = mainPanel
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6

        checkLabel.font = .systemFont(ofSize: 12, weight: .medium)
        checkLabel.textColor = Self.red
        checkLabel.stringValue = item.checked ? "✓" : ""
        addSubview(checkLabel)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = item.enabled ? Self.ink : Self.dim
        titleLabel.stringValue = item.title
        addSubview(titleLabel)

        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = Self.dim
        shortcutLabel.stringValue = item.shortcut
        shortcutLabel.alignment = .right
        addSubview(shortcutLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height; let cy = (h - 14) / 2
        let lp: CGFloat = 8; let rp: CGFloat = 8
        let ckW: CGFloat = 18; let rtW: CGFloat = item.shortcut.isEmpty ? 0 : 80
        checkLabel.frame    = NSRect(x: lp,                      y: cy, width: ckW,                                      height: 14)
        titleLabel.frame    = NSRect(x: lp + ckW,                y: cy, width: bounds.width - lp*2 - ckW - rtW,         height: 14)
        shortcutLabel.frame = NSRect(x: bounds.width - rp - rtW, y: cy, width: rtW,                                     height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { guard item.enabled else { return }; layer?.backgroundColor = Self.hover.cgColor }
    override func mouseExited(with event: NSEvent)  { layer?.backgroundColor = .clear }

    override func mouseUp(with event: NSEvent) {
        guard item.enabled, let act = item.act else { return }
        layer?.backgroundColor = .clear
        mainPanel?.close()
        act()
    }
}
