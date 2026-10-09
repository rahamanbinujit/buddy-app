import AppKit

class BuddyCharacter {
    var window: NSWindow!
    var spriteRenderer: CharacterRenderer!
    weak var controller: BuddyController?

    let displaySize: CGFloat = 80

    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true

    var blinkTimer: CFTimeInterval = 0
    var nextBlink: CFTimeInterval = 3.0
    var isBlinking = false
    var lastTick: CFTimeInterval = 0

    let accent = NSColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 1.0)

    var panelOpen = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?

    var clickOutsideMonitor: Any?
    var escapeMonitor: Any?

    private var modelConfigObserver: NSObjectProtocol?

    var session: AgentSession?
    var isStartingSession = false
    var currentStreamingText = ""

    // Voice assistant
    let voice = VoiceAssistant()
    var isVoiceMode = false
    var isVoiceTriggered = false  // true ONLY when current message came from voice input
    var voiceSentenceBuffer = ""
    var voiceSession: AgentSession?  // separate fast session for voice

    var bubbleWindow: NSWindow?
    var bubbleLabel: NSTextField?
    var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""

    var previewWindow: NSWindow?
    var previewTextView: NSTextView?
    var previewFadeTimer: Timer?

    // Focus progress bar
    var progressWindow: NSWindow?
    var progressBar: CALayer?
    var progressBg: CALayer?
    var progressLabel: NSTextField?
    var progressTimer: Timer?

    var tapTimes: [CFTimeInterval] = []
    var emotionResetTimer: Timer?
    var tapDebounceTimer: Timer?
    var effectLayers: [CALayer] = []
    var commentTimer: Timer?
    var isAutoComment = false
    private var autoCommentTimeout: Timer?

    // Spider-Man style jumping
    var isJumping = false
    var jumpStartX: CGFloat = 0
    var jumpTargetX: CGFloat = 0
    var jumpStartY: CGFloat = 0
    var jumpPeakHeight: CGFloat = 0
    var jumpProgress: CGFloat = 0
    var jumpSpeed: CGFloat = 1.8  // full jump in ~0.55 seconds
    var lastJumpTime: CFTimeInterval = 0
    var nextJumpDelay: CFTimeInterval = 0

    // Random emotion display
    var lastRandomEmotionTime: CFTimeInterval = 0
    var nextEmotionDelay: CFTimeInterval = 0
    var isShowingRandomEmotion = false

    // Web line for Spider-Man jumps
    var webLineWindow: NSWindow?
    var webLineLayer: CAShapeLayer?
    static var commentInterval: Double {
        get { UserDefaults.standard.double(forKey: "commentInterval").nonZero ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "commentInterval") }
    }

    static let workspaceDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buddy").appendingPathComponent("workspace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var lastFloorY: CGFloat = 0
    var lastDockX: CGFloat = 0
    var lastDockWidth: CGFloat = 800

    init() {
        modelConfigObserver = NotificationCenter.default.addObserver(
            forName: SettingsManager.modelConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resetSessionForSettingsChange()
        }
    }

    deinit {
        if let observer = modelConfigObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Setup

    func setup() {
        spriteRenderer = CharacterRenderer()
        guard let screen = NSScreen.main else { return }
        let y = screen.frame.origin.y
        let startX = screen.frame.width / 2 - displaySize / 2

        window = NSWindow(contentRect: CGRect(x: startX, y: y, width: displaySize, height: displaySize),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = BuddyContentView(frame: CGRect(x: 0, y: 0, width: displaySize, height: displaySize))
        host.character = self
        host.wantsLayer = true
        host.canDrawSubviewsIntoLayer = true
        host.layerContentsRedrawPolicy = .never
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let shadowLayer = CALayer()
        shadowLayer.frame = CGRect(x: 18, y: 4, width: displaySize - 36, height: 12)
        shadowLayer.cornerRadius = 6
        shadowLayer.backgroundColor = NSColor.black.withAlphaComponent(0.13).cgColor
        host.layer?.addSublayer(shadowLayer)
        host.layer?.addSublayer(spriteRenderer.layer)
        window.contentView = host
        window.orderFrontRegardless()
        lastTick = CACurrentMediaTime()

        setupVoice()
        startCommentTimer()
        lastJumpTime = CACurrentMediaTime()
        nextJumpDelay = Double.random(in: 15...30)
        lastRandomEmotionTime = CACurrentMediaTime()
        nextEmotionDelay = Double.random(in: 10...20) // first random emotion in 10-20s
    }

    // MARK: - Random Comments

    private static let hasLaunchedKey = "hasLaunchedBefore"

    func startCommentTimer() {
        commentTimer?.invalidate()
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey) {
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
            commentTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                let greeting = "hey, i'm buddy. i live on your desktop now. give me screen access so i can actually help you out"
                self.spriteRenderer.setFrame(.happy)
                self.bounce(count: 3, height: 8)
                self.showPreview(greeting, autoFade: false)
                self.previewFadeTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.5
                        self?.previewWindow?.animator().alphaValue = 0
                    }, completionHandler: { self?.previewWindow?.orderOut(nil) })
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    self?.spriteRenderer.setFrame(.idle)
                    self?.clearEffects()
                }
                self.scheduleNextComment()
            }
        } else {
            scheduleNextComment()
        }
    }

    private func scheduleNextComment() {
        commentTimer?.invalidate()
        let delay = Self.commentInterval
        commentTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.makeRandomComment()
        }
    }

    static func isBlockedApp() -> Bool {
        let excluded = PersonalContext.shared.profile.excludedApps
        guard !excluded.isEmpty else { return false }
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return excluded.contains { activeApp.lowercased().contains($0.lowercased()) }
    }

    private func makeRandomComment() {
        // Log which condition fails so we can debug
        if panelOpen { NSLog("[Comment] Skipped: panel open"); scheduleNextComment(); return }
        if isVoiceMode { NSLog("[Comment] Skipped: voice mode"); scheduleNextComment(); return }
        if Self.isBlockedApp() { NSLog("[Comment] Skipped: blocked app"); scheduleNextComment(); return }
        if session?.isBusy == true { NSLog("[Comment] Skipped: session busy"); scheduleNextComment(); return }
        if isAutoComment { NSLog("[Comment] Skipped: already auto-commenting"); scheduleNextComment(); return }
        if !currentStreamingText.isEmpty { NSLog("[Comment] Skipped: streaming text"); scheduleNextComment(); return }
        if !ScreenContext.commentsEnabled { NSLog("[Comment] Skipped: comments disabled"); scheduleNextComment(); return }
        if !ScreenContext.hasPermission { NSLog("[Comment] Skipped: no screen permission"); scheduleNextComment(); return }
        NSLog("[Comment] All checks passed, capturing screenshot...")

        if session == nil {
            let newSession = createAgentSession()
            session = newSession
            wireSession(newSession)
            isStartingSession = true
            newSession.start()
        }

        ScreenContext.captureScreenshot { [weak self] screenshot in
            guard let self = self, let img = screenshot else {
                self?.scheduleNextComment()
                return
            }
            self.isAutoComment = true

            // Safety timeout: if AI doesn't respond in 20s, reset and move on
            self.autoCommentTimeout?.invalidate()
            self.autoCommentTimeout = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
                guard let self = self, self.isAutoComment else { return }
                NSLog("[Comment] Timeout — no response in 20s, resetting")
                self.isAutoComment = false
                self.currentStreamingText = ""
                // If session died, clear it so a new one is created next time
                if self.session?.isRunning == false {
                    self.session = nil
                }
            }

            let seed = Int.random(in: 1000...9999)
            let name = PersonalContext.shared.profile.name
            let userName = name.isEmpty ? "the user" : name
            let context = PersonalContext.shared.generateSystemPromptContext()
            var prompt = "<system>[\(seed)] You're Buddy, a desktop companion sitting next to \(userName). You can see their screen right now. This is a NEW observation — comment on what you see RIGHT NOW, not what you said before."
            if !context.isEmpty { prompt += " " + context }
            prompt += " LOOK at the screenshot carefully. What app are they using? What are they working on? Be SPECIFIC. Say ONE short sentence (under 15 words) reacting to what's actually on screen — like a friend sitting next to them. Examples: 'oh nice you're working on that swift file', 'figma again huh, that layout's looking clean', 'you've been on twitter for a while lol'. If they're just on the desktop with nothing open, say something fun. Start with one emoji: 😄 😭 😡 😨 🤢 😴 💀 😍</system>"
            self.session?.send(
                message: prompt,
                screenshotBase64: img
            )
            self.scheduleNextComment()
        }
    }

    private var isAnimatingEmotion = false
    private var pendingTaps = 0

    func handleClick() {
        if panelOpen {
            closePopover()
            return
        }

        let now = CACurrentMediaTime()
        tapTimes.append(now)
        tapTimes = tapTimes.filter { now - $0 < 5.0 }.suffix(20).map { $0 }

        tapDebounceTimer?.invalidate()

        if tapTimes.count >= 2 {
            pendingTaps += 1
            if !isAnimatingEmotion {
                playNextEmotion()
            }
        } else {
            tapDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.tapTimes.count <= 1 && !self.isAnimatingEmotion {
                    self.tapTimes.removeAll()
                    self.openPopover()
                }
            }
        }
    }

    private func playNextEmotion() {
        guard pendingTaps > 0 else {
            isAnimatingEmotion = false
            return
        }
        pendingTaps = 0
        isAnimatingEmotion = true
        clearEffects()

        let count = tapTimes.count
        let mood: Int
        if count <= 4 { mood = 0 }
        else if count <= 8 { mood = 1 }
        else { mood = 2 }

        let duration: Double

        switch mood {
        case 0:
            let pick = [playHappy, playLove, playWink].randomElement()!
            duration = pick()
        case 1:
            let pick = [playSurprised, playScared, playSmug].randomElement()!
            duration = pick()
        default:
            let pick = [playAngry, playDead].randomElement()!
            duration = pick()
        }

        emotionResetTimer?.invalidate()
        emotionResetTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.spriteRenderer.setFrame(.idle)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteRenderer.layer.transform = CATransform3DIdentity
            self.spriteRenderer.layer.opacity = 1
            CATransaction.commit()
            self.clearEffects()

            if self.pendingTaps > 0 {
                self.playNextEmotion()
            } else {
                self.isAnimatingEmotion = false
                self.tapTimes.removeAll()
            }
        }
    }

    private func playHappy() -> Double {
        spriteRenderer.setFrame(.happy)
        bounce(count: 3, height: 8)
        return 1.8
    }

    private func playLove() -> Double {
        spriteRenderer.setFrame(.love)
        pulse(scale: 1.15, count: 3)
        return 2.2
    }

    private func playWink() -> Double {
        spriteRenderer.setFrame(.wink)
        tilt(angle: 0.15, duration: 0.2)
        return 1.5
    }

    private func playSurprised() -> Double {
        spriteRenderer.setFrame(.surprised)
        jump(height: 14)
        squash(scaleX: 1.2, scaleY: 0.8, duration: 0.12)
        return 1.6
    }

    private func playScared() -> Double {
        spriteRenderer.setFrame(.scared)
        tremble(intensity: 3, duration: 1.0)
        return 1.8
    }

    private func playSmug() -> Double {
        spriteRenderer.setFrame(.smug)
        tilt(angle: -0.12, duration: 0.3)
        return 1.5
    }

    private func playAngry() -> Double {
        spriteRenderer.setFrame(.angry)
        shake(intensity: 6, count: 14)
        return 2.2
    }

    private func playDead() -> Double {
        spriteRenderer.setFrame(.dead)
        shake(intensity: 4, count: 8)
        return 2.0
    }

    // MARK: - Pixel Art Effects

    enum EmotionEffect { case sparkle, heart, angerMark, sweat, skull }

    private var floatingEmojiWindows: [NSWindow] = []

    private func showEffect(_ effect: EmotionEffect) {
        let emojis: [String]
        let count: Int
        switch effect {
        case .sparkle:  emojis = ["✨", "⭐", "🌟"]; count = 3
        case .heart:    emojis = ["❤️", "💕", "💖"]; count = 3
        case .angerMark: emojis = ["💢", "😤"]; count = 2
        case .sweat:    emojis = ["💧", "😢"]; count = 2
        case .skull:    emojis = ["💀", "☠️"]; count = 2
        }
        for i in 0..<count {
            let emoji = emojis[i % emojis.count]
            let delay = Double(i) * 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.spawnFloatingEmoji(emoji)
            }
        }
    }

    private func spawnFloatingEmoji(_ emoji: String) {
        let size: CGFloat = 28
        let cf = window.frame

        // Random position above character
        let startX = cf.midX + CGFloat.random(in: -30...30) - size / 2
        let startY = cf.maxY + CGFloat.random(in: 0...10)

        let win = NSWindow(contentRect: CGRect(x: startX, y: startY, width: size, height: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 2)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let label = NSTextField(labelWithString: emoji)
        label.font = NSFont.systemFont(ofSize: 20)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: size, height: size)
        win.contentView = label

        win.alphaValue = 1
        win.orderFrontRegardless()
        floatingEmojiWindows.append(win)

        // Float upward and fade out
        let duration = 1.5
        let floatHeight: CGFloat = 60
        let steps = 30
        let stepTime = duration / Double(steps)

        for step in 0...steps {
            let t = Double(step) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + t * duration) { [weak win] in
                guard let w = win else { return }
                let y = startY + floatHeight * CGFloat(t)
                let x = startX + CGFloat(sin(t * .pi * 2)) * 8 // gentle sway
                w.setFrameOrigin(NSPoint(x: x, y: y))
                w.alphaValue = CGFloat(1.0 - t)
            }
        }

        // Remove after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
            win.orderOut(nil)
            self?.floatingEmojiWindows.removeAll { $0 === win }
        }
    }

    private func showEmojiEffect(_ emoji: String) {
        let layer = spriteRenderer.layer
        let s = CGFloat(spriteRenderer.scale)

        switch emoji {
        case "😄":
            let c = NSColor(red: 1, green: 0.95, blue: 0.4, alpha: 1)
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 2, color: .white, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 3, color: .white, on: layer, scale: s)
            addPixel(x: 14, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 4, color: c, on: layer, scale: s)
        case "😭":
            let c = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9)
            addPixel(x: 5, y: 8, color: c, on: layer, scale: s)
            addPixel(x: 5, y: 9, color: c, on: layer, scale: s)
            addPixel(x: 5, y: 10, color: c, on: layer, scale: s)
            addPixel(x: 10, y: 8, color: c, on: layer, scale: s)
            addPixel(x: 10, y: 9, color: c, on: layer, scale: s)
            addPixel(x: 10, y: 10, color: c, on: layer, scale: s)
        case "😡":
            let c = NSColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 1)
            addPixel(x: 12, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 3, color: c, on: layer, scale: s)
        case "😨":
            let c = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.9)
            addPixel(x: 13, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 6, color: c, on: layer, scale: s)
        case "🤢":
            let c = NSColor(red: 0.4, green: 0.75, blue: 0.2, alpha: 0.9)
            addPixel(x: 0, y: 6, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 0, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 15, y: 6, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 5, color: c, on: layer, scale: s)
            addPixel(x: 15, y: 4, color: c, on: layer, scale: s)
        case "😴":
            let c = NSColor(red: 0.3, green: 0.55, blue: 1.0, alpha: 0.85)
            addPixel(x: 13, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 14, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 13, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 11, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 12, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 11, y: 4, color: c, on: layer, scale: s)
            addPixel(x: 10, y: 5, color: c, on: layer, scale: s)
        case "💀":
            let c = NSColor.white.withAlphaComponent(0.85)
            addPixel(x: 1, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 4, color: c, on: layer, scale: s)
        case "😍":
            let c = NSColor.systemPink
            addPixel(x: 2, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 1, color: c, on: layer, scale: s)
            addPixel(x: 1, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 5, y: 2, color: c, on: layer, scale: s)
            addPixel(x: 2, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 4, y: 3, color: c, on: layer, scale: s)
            addPixel(x: 3, y: 4, color: c, on: layer, scale: s)
        default:
            break
        }
    }

    private func addPixel(x: Int, y: Int, color: NSColor, on parent: CALayer, scale: CGFloat) {
        let px = CALayer()
        let flippedY = 15 - y
        px.frame = CGRect(x: CGFloat(x) * scale, y: CGFloat(flippedY) * scale, width: scale, height: scale)
        px.backgroundColor = color.cgColor
        parent.addSublayer(px)
        effectLayers.append(px)
    }

    private func clearEffects() {
        for l in effectLayers { l.removeFromSuperlayer() }
        effectLayers.removeAll()
        for w in floatingEmojiWindows { w.orderOut(nil) }
        floatingEmojiWindows.removeAll()
    }

    // MARK: - Special Effects

    private func showConfetti() {
        let confettiEmojis = ["🎉", "🎊", "✨", "⭐", "🌟", "💫"]
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) { [weak self] in
                self?.spawnFloatingEmoji(confettiEmojis.randomElement()!)
            }
        }
    }

    private func showWaterDrops() {
        spawnFloatingEmoji("💧")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.spawnFloatingEmoji("🥤")
        }
    }

    private func showCheckmark() {
        spawnFloatingEmoji("✅")
    }

    // MARK: - Context-Specific Animations

    func playReminder(_ type: String) {
        clearEffects()
        switch type {
        case "water":
            spriteRenderer.setFrame(.drinking)
            tilt(angle: 0.05, duration: 0.3)
            tilt(angle: 0.08, duration: 0.3)
        case "break":
            spriteRenderer.setFrame(.stretching)
            pulse(scale: 1.05, count: 2)
        case "posture":
            spriteRenderer.setFrame(.idle)
            bounce(count: 2, height: 5)
        case "movement":
            spriteRenderer.setFrame(.stretching)
            bounce(count: 3, height: 8)
        case "eyeRest":
            spriteRenderer.setFrame(.sleepy)
            tilt(angle: 0.15, duration: 0.5)
        default:
            spriteRenderer.setFrame(.happy)
            bounce(count: 1, height: 4)
        }
        scheduleEmotionReset(duration: 4.0)
    }

    func playConcerned() {
        clearEffects()
        spriteRenderer.setFrame(.concerned)
        tilt(angle: -0.1, duration: 0.4)
        scheduleEmotionReset(duration: 5.0)
    }

    func playCelebration() {
        clearEffects()
        spriteRenderer.setFrame(.celebrate)
        bounce(count: 6, height: 14)
        scheduleEmotionReset(duration: 4.0)
    }

    func playHappyPublic() {
        clearEffects()
        spriteRenderer.setFrame(.happy)
        bounce(count: 3, height: 8)
        scheduleEmotionReset(duration: 3.0)
    }

    func playFocusStart() {
        clearEffects()
        spriteRenderer.setFrame(.focused)
        squash(scaleX: 1.15, scaleY: 0.85, duration: 0.15)
        scheduleEmotionReset(duration: 3.0)
    }

    func playDistraction() {
        clearEffects()
        spriteRenderer.setFrame(.concerned)
        shake(intensity: 3, count: 6)
        scheduleEmotionReset(duration: 3.0)
    }

    private func scheduleEmotionReset(duration: Double) {
        emotionResetTimer?.invalidate()
        emotionResetTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isWalking { self.walkFrameTimer = 0 }
            else { self.spriteRenderer.setFrame(.idle) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteRenderer.layer.transform = CATransform3DIdentity
            self.spriteRenderer.layer.opacity = 1
            CATransaction.commit()
            self.clearEffects()
        }
    }

    // MARK: - Voice Assistant

    func setupVoice() {
        voice.onStateChanged = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .listening:
                self.isVoiceMode = true
                // Pause comments and reminders during voice
                self.commentTimer?.invalidate()
                self.commentTimer = nil
                self.spriteRenderer.setFrame(.happy)
                self.bounce(count: 2, height: 4)
                self.showPreview("listening...", autoFade: false)
            case .processing:
                self.spriteRenderer.setFrame(.focused)
                self.showPreview("transcribing...", autoFade: false)
            case .speaking:
                self.spriteRenderer.setFrame(.happy)
                self.bounce(count: 1, height: 3)
            case .idle:
                if self.isVoiceMode {
                    // Only go idle if we're not waiting for Claude
                    if self.session?.isBusy != true {
                        self.isVoiceMode = false
                        self.clearEffects()
                        self.spriteRenderer.setFrame(.idle)
                        self.hidePreview()
                        // Resume comments
                        self.scheduleNextComment()
                    }
                }
            }
        }

        voice.onTranscription = { [weak self] text in
            if text.isEmpty {
                self?.hidePreview()
            } else {
                self?.showPreview("you: \(text)", autoFade: false)
            }
        }

        voice.onFinalText = { [weak self] text in
            guard let self = self, !text.isEmpty else {
                self?.isVoiceMode = false
                self?.hidePreview()
                self?.spriteRenderer.setFrame(.idle)
                self?.scheduleNextComment()
                return
            }

            // Show preview bubble with transcription + thinking (don't open chat yet)
            self.showPreview("you: \(text)\n\nthinking...", autoFade: false)
            self.spriteRenderer.setFrame(.focused)

            // Send via same path as typed messages, but don't open chat yet
            self.sendMessage(text)
            // Set voice flag AFTER sendMessage (which resets it)
            self.isVoiceTriggered = true
        }

        voice.onError = { [weak self] error in
            self?.showPreview("error: \(error)", autoFade: true)
            self?.isVoiceMode = false
            self?.spriteRenderer.setFrame(.idle)
            self?.clearEffects()
            self?.scheduleNextComment()
        }
    }

    func toggleVoice() {
        // If speaking, stop voice and start listening again
        if voice.state == .speaking {
            voice.stopSpeaking()
            isVoiceMode = true
            voice.startListening()
            return
        }
        if isVoiceMode && voice.state == .listening {
            voice.stopListening()
        } else {
            // Don't open popover yet -- just show preview bubble
            voice.startListening()
        }
    }

    // Wire voice output to AI responses
    func speakResponse(_ text: String) {
        if isVoiceMode {
            voice.speak(text)
        }
    }

    // MARK: - Focus Session Progress Bar

    func showFocusProgress(task: String, durationMinutes: Int) {
        playFocusStart()
        showPreview("focus mode: \"\(task)\" for \(durationMinutes)min. let's go!", autoFade: true)

        if progressWindow == nil { createProgressWindow() }
        guard let win = progressWindow else { return }

        updateProgressPosition()
        win.alphaValue = 1
        win.orderFrontRegardless()
        updateProgressBar()

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateProgressBar()
        }
    }

    func hideFocusProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            progressWindow?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.progressWindow?.orderOut(nil)
        })
    }

    private func createProgressWindow() {
        let w: CGFloat = 120
        let h: CGFloat = 24

        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.cornerRadius = h / 2
        container.layer?.masksToBounds = true

        // Background track
        let bg = CALayer()
        bg.frame = CGRect(x: 0, y: 0, width: w, height: h)
        bg.backgroundColor = NSColor(red: 0.95, green: 0.92, blue: 0.88, alpha: 0.95).cgColor
        bg.cornerRadius = h / 2
        container.layer?.addSublayer(bg)

        // Progress fill
        let bar = CALayer()
        bar.frame = CGRect(x: 2, y: 2, width: 0, height: h - 4)
        bar.backgroundColor = NSColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 0.85).cgColor
        bar.cornerRadius = (h - 4) / 2
        container.layer?.addSublayer(bar)

        // Time label
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(red: 0.1, green: 0.08, blue: 0.06, alpha: 0.8)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 4, width: w, height: 14)
        container.addSubview(label)

        win.contentView = container
        progressWindow = win
        progressBar = bar
        progressBg = bg
        progressLabel = label
    }

    func updateProgressPosition() {
        guard let win = progressWindow else { return }
        let cf = window.frame
        let x = cf.midX - win.frame.width / 2
        let y = cf.maxY - 8
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateProgressBar() {
        guard let session = FocusGuardian.shared.currentSession,
              let bar = progressBar,
              let win = progressWindow else {
            hideFocusProgress()
            return
        }

        let elapsed = Date().timeIntervalSince(session.startTime)
        let total = Double(session.durationMinutes) * 60
        let progress = min(elapsed / total, 1.0)
        let maxWidth = win.frame.width - 4

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        bar.frame.size.width = maxWidth * CGFloat(progress)
        CATransaction.commit()

        let remaining = max(0, Int(total - elapsed))
        let mins = remaining / 60
        let secs = remaining % 60
        progressLabel?.stringValue = String(format: "%d:%02d left", mins, secs)

        // Change color as time runs out
        if progress > 0.8 {
            bar.backgroundColor = NSColor(red: 0.3, green: 0.75, blue: 0.45, alpha: 0.85).cgColor
        }

        updateProgressPosition()
    }

    // MARK: - Animation Primitives

    private func bounce(count: Int, height: CGFloat) {
        let origin = window.frame.origin
        var delay = 0.0
        for i in 0..<count {
            let h = height * max(1.0 - CGFloat(i) * 0.25, 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + h))
            }
            delay += 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window.setFrameOrigin(origin)
            }
            delay += 0.08
        }
    }

    private func jump(height: CGFloat) {
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + height))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.window.setFrameOrigin(origin)
        }
    }

    private func shake(intensity: CGFloat, count: Int) {
        let origin = window.frame.origin
        for i in 0..<count {
            let dx = (i % 2 == 0 ? intensity : -intensity) * max(1.0 - CGFloat(i) / CGFloat(count), 0.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.035) { [weak self] in
                self?.window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 0.035) { [weak self] in
            self?.window.setFrameOrigin(origin)
        }
    }

    private func tremble(intensity: CGFloat, duration: Double) {
        let origin = window.frame.origin
        let steps = Int(duration / 0.03)
        for i in 0..<steps {
            let dx = CGFloat.random(in: -intensity...intensity)
            let dy = CGFloat.random(in: -intensity...intensity)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.03) { [weak self] in
                self?.window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.window.setFrameOrigin(origin)
        }
    }

    private func squash(scaleX: CGFloat, scaleY: CGFloat, duration: Double) {
        let layer = spriteRenderer.layer
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer.transform = CATransform3DMakeScale(scaleX, scaleY, 1)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration * 1.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    private func pulse(scale: CGFloat, count: Int) {
        let origin = window.frame.origin
        let size = window.frame.size
        let dw = size.width * (scale - 1)
        let dh = size.height * (scale - 1)
        var delay = 0.0
        for _ in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                let grown = NSRect(x: origin.x - dw / 2, y: origin.y - dh / 2, width: size.width + dw, height: size.height + dh)
                self.window.setFrame(grown, display: false)
            }
            delay += 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.window.setFrame(NSRect(origin: origin, size: size), display: false)
            }
            delay += 0.15
        }
    }

    private func tilt(angle: CGFloat, duration: Double) {
        let layer = spriteRenderer.layer
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.3) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - Popover

    func openPopover() {
        panelOpen = true
        isWalking = false
        isPaused = true
        spriteRenderer.setFrame(.idle)
        hideBubble()
        hidePreview()

        if session == nil {
            let newSession = createAgentSession()
            session = newSession
            wireSession(newSession)
            isStartingSession = true
            newSession.start()
        }

        if popoverWindow == nil {
            createPopover()
            if let session = session, !session.history.isEmpty {
                terminalView?.replayHistory(session.history)
            }
        }

        // Update model indicator
        if let inner = popoverWindow?.contentView?.subviews.first,
           let modelLabel = inner.viewWithTag(999) as? NSTextField {
            modelLabel.stringValue = SettingsManager.shared.activeModelConfig.displayName
        }

        positionPopover()
        NSApp.activate(ignoringOtherApps: true)
        // Defer ordering so it fires after activation reshuffles the window stack
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.popoverWindow?.orderFrontRegardless()
            self.popoverWindow?.makeKey()
            self.popoverWindow?.makeFirstResponder(self.terminalView?.inputField)
        }

        removeMonitors()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let mouse = NSEvent.mouseLocation
            let inPanel = self.popoverWindow?.frame.contains(mouse) ?? false
            let inChar = self.window.frame.contains(mouse)
            if !inPanel && !inChar { self.closePopover() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closePopover(); return nil }
            return event
        }
    }

    func closePopover() {
        guard panelOpen else { return }
        popoverWindow?.orderOut(nil)
        removeMonitors()
        panelOpen = false

        // Stop voice if speaking
        if isVoiceMode || isVoiceTriggered {
            voice.stopSpeaking()
            voice.stopListening()
            isVoiceMode = false
            isVoiceTriggered = false
            hidePreview()
            spriteRenderer.setFrame(.idle)
            scheduleNextComment()
        }

        if session?.isBusy == true {
            currentPhrase = ""
            lastPhraseUpdate = 0
        }

        pauseEndTime = CACurrentMediaTime() + Double.random(in: 2.0...4.0)
    }

    func createPopover() {
        let w: CGFloat = 300
        let h: CGFloat = 240

        let win = KeyableWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                                styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let body = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        body.wantsLayer = true
        body.layer?.cornerRadius = 18
        body.layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        body.layer?.shadowOpacity = 1
        body.layer?.shadowRadius = 16
        body.layer?.shadowOffset = CGSize(width: 0, height: -3)
        body.layer?.masksToBounds = false

        let inner = NSView(frame: body.bounds)
        inner.wantsLayer = true
        inner.layer?.backgroundColor = PetTheme.paper.cgColor
        inner.layer?.cornerRadius = 18
        inner.layer?.masksToBounds = true
        body.addSubview(inner)

        let modelLabelH: CGFloat = 16
        let terminal = TerminalView(
            frame: NSRect(x: 0, y: modelLabelH, width: inner.bounds.width, height: inner.bounds.height - modelLabelH),
            accentColor: accent
        )
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self] message in
            self?.sendMessage(message)
        }
        inner.addSubview(terminal)

        let modelLabel = NSTextField(labelWithString: "")
        modelLabel.font = PetFonts.rounded(size: 9, weight: .medium)
        modelLabel.textColor = PetTheme.ink.withAlphaComponent(0.25)
        modelLabel.frame = NSRect(x: 10, y: 2, width: w - 20, height: modelLabelH - 2)
        modelLabel.tag = 999
        inner.addSubview(modelLabel)

        win.contentView = body
        popoverWindow = win
        terminalView = terminal
    }

    func positionPopover() {
        guard let win = popoverWindow, let screen = NSScreen.main else { return }
        let cf = window.frame
        var x = cf.midX - win.frame.width / 2
        let y = cf.maxY - 14
        x = max(screen.frame.minX + 4, min(x, screen.frame.maxX - win.frame.width - 4))
        win.setFrameOrigin(NSPoint(x: x, y: min(y, screen.frame.maxY - win.frame.height - 4)))
    }

    // MARK: - Send

    private func sendMessage(_ text: String) {
        isVoiceTriggered = false  // typed message, don't speak response
        terminalView?.appendUser(text)
        terminalView?.showThinking()

        if session == nil {
            let newSession = createAgentSession()
            session = newSession
            wireSession(newSession)
            isStartingSession = true
            newSession.start()
        }

        let sendToSession: (String?) -> Void = { [weak self] screenshot in
            self?.session?.send(message: text, screenshotBase64: screenshot)
        }

        if ScreenContext.chatEnabled && ScreenContext.hasPermission && !Self.isBlockedApp() {
            ScreenContext.captureScreenshot(completion: sendToSession)
        } else {
            sendToSession(nil)
        }
    }

    // MARK: - Session

    func wireSession(_ s: AgentSession) {
        s.onSessionReady = { [weak self] in
            self?.isStartingSession = false
        }

        s.onText = { [weak self] delta in
            guard let self = self else { return }
            if self.isAutoComment {
                NSLog("[Comment] onText (auto): %@", String(delta.prefix(100)))
            }
            if self.currentStreamingText.isEmpty && !self.isAutoComment {
                self.terminalView?.removeThinking()
            }
            self.currentStreamingText += delta

            if self.isAutoComment { return }

            self.terminalView?.appendStreamingText(delta)
            if !self.panelOpen {
                if self.isVoiceTriggered {
                    // For voice: replace the "thinking..." preview with streaming response
                    self.showPreview(self.currentStreamingText, autoFade: false)
                } else {
                    self.appendToPreview(delta)
                }
            }
        }

        s.onTurnComplete = { [weak self] in
            guard let self = self else { return }
            let finalText = self.currentStreamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasAuto = self.isAutoComment
            self.isAutoComment = false
            self.currentStreamingText = ""
            NSLog("[Comment] onTurnComplete: wasAuto=%d, finalText='%@'", wasAuto ? 1 : 0, String(finalText.prefix(200)))

            if wasAuto {
                self.autoCommentTimeout?.invalidate()
                if !finalText.isEmpty {
                    let (emoji, comment) = self.parseEmotion(finalText)
                    self.showEmotion(emoji, forText: comment)
                    self.showPreview(comment, autoFade: true)
                    let display = emoji.isEmpty ? comment : "\(emoji) \(comment)"
                    self.terminalView?.appendProactive(display)
                    NSLog("[Comment] Showing bubble: %@", display)
                }
                return
            }

            self.terminalView?.endStreaming()
            if !self.panelOpen && !finalText.isEmpty {
                self.showPreview(finalText, autoFade: true)
            }
            self.hideBubble()

            // Only speak if this message was triggered by voice input
            if self.isVoiceTriggered && !finalText.isEmpty {
                self.hidePreview()
                // NOW open chat window — user sees their message + reply
                if !self.panelOpen { self.openPopover() }

                self.spriteRenderer.setFrame(.happy)
                self.bounce(count: 1, height: 3)
                self.voice.speak(finalText)

                // Wait for speech to finish, then go idle
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                    guard let self = self else { timer.invalidate(); return }
                    if !self.voice.isSpeakingQueue && self.voice.state != .speaking {
                        timer.invalidate()
                        self.isVoiceMode = false
                        self.isVoiceTriggered = false
                        self.spriteRenderer.setFrame(.idle)
                        self.scheduleNextComment()
                    }
                }
            } else if self.isVoiceTriggered {
                self.isVoiceMode = false
                self.isVoiceTriggered = false
                self.hidePreview()
                self.spriteRenderer.setFrame(.idle)
                self.scheduleNextComment()
            }

            // Save conversation to memory
            if !finalText.isEmpty, let lastUserMsg = self.session?.history.last(where: { $0.role == .user }) {
                MemoryStore.shared.saveConversation(userMessage: lastUserMsg.text, buddyResponse: finalText, context: "")
            }
        }

        s.onError = { [weak self] text in
            NSLog("[Session] Error: %@", text)
            self?.terminalView?.removeThinking()
            self?.terminalView?.endStreaming()
            self?.terminalView?.appendError(text)
            self?.isStartingSession = false
            self?.isAutoComment = false
            self?.autoCommentTimeout?.invalidate()
            self?.currentStreamingText = ""
            if self?.isVoiceTriggered == true {
                self?.isVoiceMode = false
                self?.isVoiceTriggered = false
                self?.hidePreview()
                self?.spriteRenderer?.setFrame(.idle)
                self?.scheduleNextComment()
            }
            if self?.session?.isRunning == false {
                self?.session = nil
            }
        }

        s.onToolUse = { [weak self] name, input in
            let summary = ClaudeSession.formatToolSummary(name: name, input: input)
            self?.terminalView?.appendToolUse(summary)
        }

        s.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary, isError: isError)
        }

        s.onProcessExit = { [weak self] in
            NSLog("[Session] Process exited, resetting state")
            self?.terminalView?.removeThinking()
            self?.terminalView?.endStreaming()
            self?.terminalView?.appendError("Session ended.")
            self?.isStartingSession = false
            self?.isAutoComment = false
            self?.autoCommentTimeout?.invalidate()
            self?.currentStreamingText = ""
            self?.session = nil
        }
    }

    private func resetSessionForSettingsChange() {
        if let oldSession = session {
            oldSession.onText = nil
            oldSession.onError = nil
            oldSession.onToolUse = nil
            oldSession.onToolResult = nil
            oldSession.onSessionReady = nil
            oldSession.onTurnComplete = nil
            oldSession.onProcessExit = nil
            oldSession.terminate()
        }
        session = nil
        voiceSession?.terminate()
        voiceSession = nil
        isVoiceMode = false
        isVoiceTriggered = false
        isStartingSession = false
        isAutoComment = false
        autoCommentTimeout?.invalidate()
        currentStreamingText = ""
        terminalView?.removeThinking()
        terminalView?.endStreaming()
        if let inner = popoverWindow?.contentView?.subviews.first,
           let modelLabel = inner.viewWithTag(999) as? NSTextField {
            modelLabel.stringValue = SettingsManager.shared.activeModelConfig.displayName
        }
    }

    func clearConversation() {
        session?.terminate()
        session = nil
        isStartingSession = false
        currentStreamingText = ""
        terminalView?.clear()
        hideBubble()
        hidePreview()
    }

    private func removeMonitors() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
    }

    // MARK: - Emotions

    private static let emojiMap: [(String, CharacterRenderer.Frame)] = [
        ("😄", .happy),
        ("😭", .sad),
        ("😡", .angry),
        ("😨", .scared),
        ("🤢", .smug),
        ("😴", .sleepy),
        ("💀", .dead),
        ("😍", .love),
        ("🎉", .celebrate),
        ("🥤", .drinking),
        ("🧘", .stretching),
        ("🤔", .concerned),
        ("🎯", .focused),
        ("🙌", .cheering),
    ]

    private func parseEmotion(_ text: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (emoji, _) in Self.emojiMap {
            if trimmed.hasPrefix(emoji) {
                let rest = String(trimmed.dropFirst(emoji.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (emoji, rest.isEmpty ? trimmed : rest)
            }
        }
        return ("", trimmed)
    }

    func triggerEmotion(_ emoji: String) {
        showEmotion(emoji, forText: "")
    }

    private func showEmotion(_ emoji: String, forText text: String = "") {
        clearEffects()
        let frame = Self.emojiMap.first(where: { $0.0 == emoji })?.1 ?? .idle
        spriteRenderer.setFrame(frame)

        switch emoji {
        case "😄": bounce(count: 3, height: 8)
        case "😭": bounce(count: 1, height: 3)
        case "😡": shake(intensity: 6, count: 14)
        case "😨": tremble(intensity: 3, duration: 1.0)
        case "🤢": tilt(angle: -0.12, duration: 0.3)
        case "😴": tilt(angle: 0.15, duration: 0.5)
        case "💀": shake(intensity: 4, count: 8)
        case "😍": pulse(scale: 1.15, count: 3)
        case "🎉": bounce(count: 6, height: 12)
        case "🥤": tilt(angle: 0.08, duration: 0.3)
        case "🧘": pulse(scale: 1.08, count: 3)
        case "🤔": tilt(angle: -0.1, duration: 0.4)
        case "🎯": squash(scaleX: 1.15, scaleY: 0.85, duration: 0.15)
        case "🙌": bounce(count: 5, height: 14)
        default: break
        }
        let words = text.split(separator: " ").count
        let dur = max(2.0, min(Double(words) * 0.4 + 1.5, 8.0))
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in
            guard let self = self else { return }
            if self.isWalking { self.walkFrameTimer = 0 }
            else { self.spriteRenderer.setFrame(.idle) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteRenderer.layer.transform = CATransform3DIdentity
            self.spriteRenderer.layer.opacity = 1
            CATransaction.commit()
            self.clearEffects()
        }
    }

    // MARK: - Status Bubble (thinking phrases)

    private static let thinkPhrases = [
        "Thinking", "Pondering", "Reasoning", "Composing", "Computing",
        "Crafting", "Generating", "Imagining", "Mapping", "Mulling",
        "Synthesizing", "Processing", "Connecting", "Considering",
        "Contemplating", "Working", "Brewing", "Noodling", "Ruminating",
        "Percolating", "Simmering", "Marinating", "Hatching", "Tinkering",
        "Cogitating", "Ideating", "Musing", "Puzzling", "Orchestrating",
        "Deciphering", "Crystallizing", "Fermenting", "Incubating",
        "Forging", "Manifesting", "Crunching", "Calculating",
        "Cerebrating", "Zigzagging", "Caramelizing", "Booping",
        "Befuddling", "Finagling", "Canoodling", "Discombobulating",
        "Bloviating", "Boogieing", "Boondoggling", "Catapulting",
        "Transmuting", "Spinning", "Envisioning", "Burrowing",
    ]

    func updateStatusBubble() {
        let now = CACurrentMediaTime()

        if session?.isBusy == true && !panelOpen && !isAutoComment && currentStreamingText.isEmpty {
            if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
                var next = Self.thinkPhrases.randomElement() ?? "..."
                while next == currentPhrase && Self.thinkPhrases.count > 1 {
                    next = Self.thinkPhrases.randomElement() ?? "..."
                }
                currentPhrase = next
                lastPhraseUpdate = now
            }
            showBubble(text: currentPhrase)
        } else {
            hideBubble()
        }
    }

    func showBubble(text: String) {
        if bubbleWindow == nil { createBubble() }
        guard let win = bubbleWindow, let label = bubbleLabel else { return }

        let font = PetFonts.rounded(size: 11, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bw = max(ceil(textSize.width) + 24, 48)
        let bh: CGFloat = 26

        let cf = window.frame
        let x = cf.midX - bw / 2
        let y = cf.maxY - 16
        win.setFrame(CGRect(x: x, y: y, width: bw, height: bh), display: false)

        if let container = win.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bw, height: bh)
            label.stringValue = text
            label.font = font
            label.frame = NSRect(x: 0, y: 4, width: bw, height: 18)
        }

        if !win.isVisible {
            win.alphaValue = 1.0
            win.orderFrontRegardless()
        }
    }

    func hideBubble() {
        bubbleWindow?.orderOut(nil)
        currentPhrase = ""
    }

    func createBubble() {
        let w: CGFloat = 80
        let h: CGFloat = 26
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = PetTheme.paper.withAlphaComponent(0.95).cgColor
        container.layer?.cornerRadius = h / 2
        container.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = PetFonts.rounded(size: 11, weight: .semibold)
        label.textColor = PetTheme.ink.withAlphaComponent(0.5)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 4, width: w, height: 18)
        container.addSubview(label)

        win.contentView = container
        bubbleWindow = win
        bubbleLabel = label
    }

    // MARK: - Response Preview

    private let previewW: CGFloat = 260
    private let previewPad: CGFloat = 10

    private func layoutPreview() {
        guard let tv = previewTextView,
              let win = previewWindow,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else { return }
        let innerW = previewW - previewPad * 2
        tc.containerSize = NSSize(width: innerW, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let textH = ceil(used.height) + 8
        let ph = max(textH + previewPad * 2, 34)

        let cf = window.frame
        var x = cf.midX - previewW / 2
        if let s = NSScreen.main { x = max(s.frame.minX + 4, min(x, s.frame.maxX - previewW - 4)) }

        win.setFrame(CGRect(x: x, y: cf.maxY + 6, width: previewW, height: ph), display: true)
        tv.frame = NSRect(x: previewPad, y: previewPad, width: innerW, height: textH)
    }

    func appendToPreview(_ delta: String) {
        hideBubble()
        if previewWindow == nil { createPreview() }
        guard let tv = previewTextView, let win = previewWindow else { return }

        tv.textStorage?.append(NSAttributedString(string: delta, attributes: [
            .font: PetFonts.rounded(size: 13, weight: .regular),
            .foregroundColor: PetTheme.ink
        ]))
        layoutPreview()

        if !win.isVisible {
            win.alphaValue = 1
            win.orderFrontRegardless()
        }
    }

    func showPreview(_ text: String, autoFade: Bool) {
        previewFadeTimer?.invalidate()
        previewFadeTimer = nil
        hideBubble()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if previewWindow == nil { createPreview() }
        guard let tv = previewTextView, let win = previewWindow else { return }

        tv.textStorage?.setAttributedString(renderPreviewMarkdown(trimmed))
        layoutPreview()

        win.alphaValue = 1
        win.orderFrontRegardless()

        if autoFade {
            let words = trimmed.split(separator: " ").count
            let dur = max(8.0, min(Double(words) * 0.5 + 5.0, 15.0))
            previewFadeTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    self?.previewWindow?.animator().alphaValue = 0
                }, completionHandler: { self?.previewWindow?.orderOut(nil) })
            }
        }
    }

    private func renderPreviewMarkdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = PetFonts.rounded(size: 13, weight: .regular)
        let boldFont = PetFonts.rounded(size: 13, weight: .bold)
        let codeFont = PetFonts.mono(size: 12, weight: .regular)
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let code = codeLines.joined(separator: "\n")
                    result.append(NSAttributedString(string: code + "\n", attributes: [
                        .font: codeFont, .foregroundColor: PetTheme.ink,
                        .backgroundColor: PetTheme.milk
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock { codeLines.append(line); continue }

            if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: PetFonts.rounded(size: 14, weight: .bold), .foregroundColor: accent
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(NSAttributedString(string: "  \u{2022} " + String(line.dropFirst(2)) + suffix, attributes: [
                    .font: font, .foregroundColor: PetTheme.ink
                ]))
            } else {
                result.append(renderInline(line + suffix, font: font, boldFont: boldFont, codeFont: codeFont))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            result.append(NSAttributedString(string: codeLines.joined(separator: "\n") + "\n", attributes: [
                .font: codeFont, .foregroundColor: PetTheme.ink, .backgroundColor: PetTheme.milk
            ]))
        }

        return result
    }

    private func renderInline(_ text: String, font: NSFont, boldFont: NSFont, codeFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "`" {
                let after = text.index(after: i)
                if after < text.endIndex, let close = text[after...].firstIndex(of: "`") {
                    result.append(NSAttributedString(string: String(text[after..<close]), attributes: [
                        .font: codeFont, .foregroundColor: accent, .backgroundColor: PetTheme.milk
                    ]))
                    i = text.index(after: close); continue
                }
            }
            if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    result.append(NSAttributedString(string: String(text[start..<range.lowerBound]), attributes: [
                        .font: boldFont, .foregroundColor: PetTheme.ink
                    ]))
                    i = range.upperBound; continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: font, .foregroundColor: PetTheme.ink
            ]))
            i = text.index(after: i)
        }
        return result
    }

    func hidePreview() {
        previewFadeTimer?.invalidate()
        previewFadeTimer = nil
        previewWindow?.orderOut(nil)
    }

    func createPreview() {
        let pw: CGFloat = 260
        let ph: CGFloat = 40

        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: pw, height: ph),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let card = PreviewCardView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
        card.onTap = { [weak self] in self?.hidePreview() }

        let tv = NSTextView(frame: NSRect(x: 10, y: 10, width: pw - 20, height: ph - 20))
        tv.isEditable = false
        tv.isSelectable = false
        tv.backgroundColor = .clear
        tv.isRichText = true
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        card.addSubview(tv)

        win.contentView = card
        previewWindow = win
        previewTextView = tv
    }

    // MARK: - Dragging

    var isDragging = false
    var isFalling = false
    var fallVelocity: CGFloat = 0
    let gravity: CGFloat = 2800
    let bounceDamping: CGFloat = 0.4
    let minBounceVelocity: CGFloat = 80

    func stopForDrag() {
        isDragging = true
        isFalling = false
        fallVelocity = 0
        isWalking = false
        isPaused = true
        spriteRenderer.setFrame(.surprised)
    }

    func startFalling() {
        isDragging = false
        isFalling = true
        fallVelocity = 0
        spriteRenderer.setFrame(.scared)
    }

    func updateFalling(dt: CFTimeInterval, floorY: CGFloat) {
        fallVelocity += gravity * CGFloat(dt)
        var y = window.frame.origin.y - fallVelocity * CGFloat(dt)

        if y <= floorY {
            y = floorY
            if fallVelocity > minBounceVelocity {
                fallVelocity = -fallVelocity * bounceDamping
            } else {
                isFalling = false
                fallVelocity = 0
                spriteRenderer.setFrame(.idle)
                walkPixelX = window.frame.origin.x
                pauseEndTime = CACurrentMediaTime() + Double.random(in: 2.0...5.0)
            }
        }

        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: y))

        if let pw = previewWindow, pw.isVisible {
            let cf = window.frame
            let ps = pw.frame.size
            var px = cf.midX - ps.width / 2
            if let s = NSScreen.main { px = max(s.frame.minX + 4, min(px, s.frame.maxX - ps.width - 4)) }
            pw.setFrameOrigin(NSPoint(x: px, y: cf.maxY + 6))
        }
    }

    // MARK: - Walking

    var walkPixelX: CGFloat = 0
    var walkTargetX: CGFloat = 0
    let walkSpeed: CGFloat = 60
    private var walkFrameTimer: CFTimeInterval = 0
    private var walkFrameToggle = false

    func startWalk() {
        let cf = window.frame
        let curX = cf.origin.x
        let margin: CGFloat = 4
        let leftEdge = lastDockX + margin
        let rightEdge = lastDockX + lastDockWidth - displaySize - margin

        if curX >= rightEdge - 20 {
            goingRight = false
        } else if curX <= leftEdge + 20 {
            goingRight = true
        } else {
            goingRight = Bool.random()
        }

        let walkDist = CGFloat.random(in: 80...200)
        walkPixelX = curX

        if goingRight {
            walkTargetX = min(curX + walkDist, rightEdge)
        } else {
            walkTargetX = max(curX - walkDist, leftEdge)
        }

        isPaused = false
        isWalking = true
        walkFrameTimer = 0
        walkFrameToggle = false
        spriteRenderer.setFlipped(!goingRight)
        spriteRenderer.setFrame(.walkA)
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        spriteRenderer.setFrame(.idle)
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 4.0...10.0)
    }

    func startJump() {
        guard !isJumping else { return }
        isJumping = true
        isPaused = false
        isWalking = false
        jumpProgress = 0
        jumpStartX = window.frame.origin.x
        jumpStartY = lastFloorY

        // Jump to a random spot left or right (100-300px away)
        let jumpDist = CGFloat.random(in: 100...300) * (Bool.random() ? 1 : -1)
        jumpTargetX = jumpStartX + jumpDist

        // Clamp to screen bounds
        if let screen = NSScreen.main {
            jumpTargetX = max(screen.frame.minX + 10, min(jumpTargetX, screen.frame.maxX - displaySize - 10))
        }

        // Jump height: 2-3x character size
        jumpPeakHeight = CGFloat.random(in: 160...240)

        // Face the jump direction
        spriteRenderer.setFlipped(jumpTargetX < jumpStartX)
        spriteRenderer.setFrame(.stretching) // clean web-shoot pose for jumping
        showWebLine()
    }

    // MARK: - Web Line for Jumps

    private func showWebLine() {
        if webLineWindow == nil {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let contentView = NSView(frame: screen.frame)
            contentView.wantsLayer = true
            win.contentView = contentView

            let shape = CAShapeLayer()
            shape.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
            shape.lineWidth = 1.5
            shape.fillColor = nil
            shape.lineDashPattern = [3, 3]
            contentView.layer?.addSublayer(shape)

            webLineWindow = win
            webLineLayer = shape
        }
        webLineWindow?.orderFrontRegardless()
    }

    private func updateWebLine() {
        guard isJumping, let shape = webLineLayer, let screen = NSScreen.main else { return }
        let charMid = CGPoint(x: window.frame.midX, y: window.frame.maxY)
        // Web attaches to a point above and ahead of the jump arc
        let anchorX = (jumpStartX + jumpTargetX) / 2
        let anchorY = jumpStartY + jumpPeakHeight + 40
        let anchor = CGPoint(x: anchorX, y: anchorY)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: charMid.x - screen.frame.origin.x, y: charMid.y - screen.frame.origin.y))
        path.addLine(to: CGPoint(x: anchor.x - screen.frame.origin.x, y: anchor.y - screen.frame.origin.y))
        shape.path = path
    }

    private func hideWebLine() {
        webLineLayer?.path = nil
        webLineWindow?.orderOut(nil)
    }

    // MARK: - Random Emotions

    private func playRandomEmotion() {
        let emotions: [(CharacterRenderer.Frame, () -> Void, Double)] = [
            (.happy, { [weak self] in self?.bounce(count: 2, height: 6) }, 2.0),
            (.love, { [weak self] in self?.pulse(scale: 1.12, count: 2) }, 2.5),
            (.surprised, { [weak self] in self?.jump(height: 10) }, 1.5),
            (.wink, { [weak self] in self?.tilt(angle: 0.12, duration: 0.2) }, 1.5),
            (.smug, { [weak self] in self?.tilt(angle: -0.1, duration: 0.3) }, 1.8),
            (.sleepy, { [weak self] in self?.tilt(angle: 0.12, duration: 0.4) }, 2.0),
            (.celebrate, { [weak self] in self?.bounce(count: 4, height: 10) }, 2.5),
            (.happy, { [weak self] in self?.bounce(count: 1, height: 4) }, 1.5),
            (.scared, { [weak self] in self?.tremble(intensity: 2, duration: 0.8) }, 1.8),
        ]

        let pick = emotions.randomElement()!
        isShowingRandomEmotion = true
        spriteRenderer.setFrame(pick.0)
        pick.1()

        DispatchQueue.main.asyncAfter(deadline: .now() + pick.2) { [weak self] in
            guard let self = self else { return }
            self.isShowingRandomEmotion = false
            if self.isWalking {
                self.walkFrameTimer = 0
            } else {
                self.spriteRenderer.setFrame(.idle)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteRenderer.layer.transform = CATransform3DIdentity
            self.spriteRenderer.layer.opacity = 1
            CATransaction.commit()
        }
    }

    func update(floorY: CGFloat, dockX: CGFloat, dockWidth: CGFloat) {
        lastFloorY = floorY
        lastDockX = dockX
        lastDockWidth = dockWidth
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now

        blinkTimer += dt
        let emotionActive = !effectLayers.isEmpty || isAnimatingEmotion
        if !isBlinking && !emotionActive && blinkTimer > nextBlink {
            isBlinking = true; blinkTimer = 0; spriteRenderer.setFrame(.blink)
        }
        if isBlinking && blinkTimer > 0.15 {
            isBlinking = false; blinkTimer = 0; nextBlink = 2 + Double.random(in: 0...4)
            if !isWalking && !emotionActive { spriteRenderer.setFrame(.idle) }
        }

        if isDragging {
            return
        }

        if isFalling {
            updateFalling(dt: dt, floorY: floorY)
            return
        }

        if panelOpen {
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: floorY))
            positionPopover()
            return
        }

        // Spider-Man arc jump with web line
        if isJumping {
            jumpProgress += CGFloat(dt) * jumpSpeed
            if jumpProgress >= 1.0 {
                // Land
                jumpProgress = 1.0
                isJumping = false
                let landX = jumpTargetX
                window.setFrameOrigin(NSPoint(x: landX, y: floorY))
                walkPixelX = landX
                spriteRenderer.setFrame(.idle)
                squash(scaleX: 1.2, scaleY: 0.8, duration: 0.1)
                hideWebLine()
                enterPause()
            } else {
                // Parabolic arc
                let t = jumpProgress
                let currentX = jumpStartX + (jumpTargetX - jumpStartX) * t
                let currentY = jumpStartY + jumpPeakHeight * 4 * t * (1 - t)
                window.setFrameOrigin(NSPoint(x: currentX, y: currentY))
                // Update web line from hand to anchor point
                updateWebLine()
            }
            // Keep bubble, preview, and progress bar stuck to character during jump
            updateStatusBubble()
            if let pw = previewWindow, pw.isVisible {
                let cf = window.frame
                let ps = pw.frame.size
                var px = cf.midX - ps.width / 2
                if let s = NSScreen.main { px = max(s.frame.minX + 4, min(px, s.frame.maxX - ps.width - 4)) }
                pw.setFrameOrigin(NSPoint(x: px, y: cf.maxY + 6))
            }
            if let pgw = progressWindow, pgw.isVisible {
                updateProgressPosition()
            }
            return
        }

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            }
            return
        }

        // Mid-walk random jump check (Spider-Man style)
        if isWalking && !isJumping {
            if (now - lastJumpTime) > nextJumpDelay {
                lastJumpTime = now
                nextJumpDelay = Double.random(in: 30...60)
                startJump()
                return
            }
        }

        // Random emotion display while walking/idle
        if (isWalking || isPaused) && !isShowingRandomEmotion && !panelOpen && !isVoiceMode {
            if (now - lastRandomEmotionTime) > nextEmotionDelay {
                lastRandomEmotionTime = now
                nextEmotionDelay = Double.random(in: 15...35)
                playRandomEmotion()
            }
        }

        if isWalking {
            walkFrameTimer += dt
            if walkFrameTimer >= 0.2 {
                walkFrameTimer = 0
                walkFrameToggle.toggle()
                spriteRenderer.setFrame(walkFrameToggle ? .walkA : .walkB)
            }
            let step = walkSpeed * CGFloat(dt)
            let prevX = walkPixelX
            if goingRight {
                walkPixelX += step
                if walkPixelX >= walkTargetX { walkPixelX = walkTargetX; enterPause() }
            } else {
                walkPixelX -= step
                if walkPixelX <= walkTargetX { walkPixelX = walkTargetX; enterPause() }
            }
            if abs(walkPixelX - prevX) > 0.01 || window.frame.origin.y != floorY {
                window.setFrameOrigin(NSPoint(x: walkPixelX, y: floorY))
            }
        }

        updateStatusBubble()

        if let pw = previewWindow, pw.isVisible {
            let cf = window.frame
            let ps = pw.frame.size
            var px = cf.midX - ps.width / 2
            if let s = NSScreen.main { px = max(s.frame.minX + 4, min(px, s.frame.maxX - ps.width - 4)) }
            pw.setFrameOrigin(NSPoint(x: px, y: cf.maxY + 6))
        }

        if let pgw = progressWindow, pgw.isVisible {
            updateProgressPosition()
        }
    }
}

// MARK: - Support

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

enum PetTheme {
    static let shell = NSColor(red: 0.878, green: 0.122, blue: 0.122, alpha: 1.0)  // #E01F1F Spider-Man red
    static let paper = NSColor(red: 0.075, green: 0.075, blue: 0.118, alpha: 1.0)  // #131320 dark bg
    static let milk  = NSColor(red: 0.118, green: 0.118, blue: 0.176, alpha: 1.0)  // #1E1E2D input/card bg
    static let blush = NSColor(red: 0.169, green: 0.271, blue: 0.831, alpha: 1.0)  // #2B45D4 Spider-Man blue
    static let ink   = NSColor(red: 0.906, green: 0.910, blue: 0.945, alpha: 1.0)  // #E7E8F1 light text
}

enum PetFonts {
    static func rounded(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
