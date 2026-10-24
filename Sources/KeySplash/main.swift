// SPDX-License-Identifier: GPL-3.0-or-later
// Cleaning Mode behavior is adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI

@main
struct KeySplashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = CleaningModeManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        manager.applicationDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class CleaningModeManager: ObservableObject {
    private static let escapeKeyCode: Int64 = 53
    fileprivate static let threshold = 5
    private static let pressWindow: TimeInterval = 6
    private static let releaseWaitLimit: TimeInterval = 5
    private static let burstWindow: TimeInterval = 2.0
    private static let maximumBurstLevel = 7
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!

    @Published private(set) var unlockProgress = 0
    @Published private(set) var marks: [SplashMark] = []
    @Published private(set) var ambientEffects: [AmbientEffect] = []
    @Published private(set) var returnedFromSettings = false
    @Published private(set) var setupStatus = "KeySplash needs Accessibility access to capture keyboard input while play mode is active."

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panels: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var escapeCount = 0
    private var lastEscapeTime = -Double.greatestFiniteMagnitude
    private var heldButtons: Set<Int64> = []
    private var unlockPending = false
    private var unlockDeadline: DispatchWorkItem?
    private var nextMarkID = 0
    private var nextAmbientEffectID = 0
    private var activeBurstMarkIDs: Set<Int> = []
    private var burstLevel = 0
    private var lastStampTime: TimeInterval = 0
    private var nextAmbientEventTime: TimeInterval = 0
    private var ambientTask: Task<Void, Never>?
    private var setupWindow: NSWindow?
    private var waitingForSettingsReturn = false
    private let playfulSound = PlayfulSound()
    @Published private(set) var soundEnabled = true
    private let colors: [Color] = [.pink, .cyan, .yellow, .purple, .green, .orange, .blue]

    func activate() {
        guard tap == nil else { return }
        guard HandprintLibrary.variants.count == 4 else {
            showHandprintFailure()
            return
        }
        guard AXIsProcessTrusted() else {
            showAccessibilitySetup()
            return
        }
        guard installTap() else {
            showTapFailure()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        // Keep macOS Force Quit available as an emergency exit.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        setupWindow?.orderOut(nil)
        installScreenObserver()
        showOverlays()
        startAmbientEvents()
    }

    func applicationDidBecomeActive() {
        guard waitingForSettingsReturn else { return }
        waitingForSettingsReturn = false
        returnedFromSettings = true
        checkAccessibilityPermission()
    }

    func openAccessibilitySettings() {
        waitingForSettingsReturn = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            setupStatus = "System Settings could not be opened. Open Privacy & Security → Accessibility manually, then return here."
            return
        }
        setupStatus = "In System Settings, turn on KeySplash under Privacy & Security → Accessibility, then return here."
    }

    func checkAccessibilityPermission() {
        guard AXIsProcessTrusted() else {
            returnedFromSettings = true
            setupStatus = "KeySplash still cannot see the permission. Check that its switch is on. If it is, reopen KeySplash below so macOS can refresh the permission."
            return
        }
        returnedFromSettings = false
        setupStatus = "Access granted. Starting KeySplash…"
        activate()
    }

    func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                guard error == nil else {
                    self.setupStatus = "KeySplash could not reopen automatically. Quit it, then open KeySplash from Applications."
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    func quitSetup() { NSApp.terminate(nil) }

    private func installTap() -> Bool {
        var mask: CGEventMask = 0
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                  .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                  .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                  .scrollWheel, Self.systemDefinedEventType] {
            mask |= CGEventMask(1) << type.rawValue
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<CleaningModeManager>.fromOpaque(context).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if AXIsProcessTrusted(), let tap {
                heldButtons.removeAll()
                CGEvent.tapEnable(tap: tap, enable: true)
                if unlockPending { finishUnlock() }
                return nil
            }
            DispatchQueue.main.async { self.finishUnlock() }
            return Unmanaged.passUnretained(event)
        }

        if let button = mouseButton(type: type, event: event) {
            if button.down {
                heldButtons.insert(button.number)
            } else {
                heldButtons.remove(button.number)
                if unlockPending && heldButtons.isEmpty { DispatchQueue.main.async { self.finishUnlock() } }
            }
        }

        if isPointerEvent(type) {
            let overControls = panels.contains(where: isPointerOverControls)
            guard overControls else { return nil }
            if type == .leftMouseDown { NSApp.activate(ignoringOtherApps: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == Self.systemDefinedEventType {
            if let key = systemKey(from: event) {
                resetUnlockProgress()
                if key.isDown && !key.isRepeat, let keyCode = key.keyboardKeyCode {
                    addMark(for: keyCode, keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType))
                }
            }
            return nil
        }

        if type == .keyDown || type == .flagsChanged {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let repeated = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == Self.escapeKeyCode {
                if !repeated {
                    addMark(for: code, keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType))
                    let now = ProcessInfo.processInfo.systemUptime
                    escapeCount = now - lastEscapeTime <= Self.pressWindow ? escapeCount + 1 : 1
                    lastEscapeTime = now
                    unlockProgress = escapeCount
                    if escapeCount >= Self.threshold { requestUnlock() }
                }
            } else {
                resetUnlockProgress()
                if type == .keyDown && !repeated {
                    addMark(for: code, keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType))
                } else if type == .flagsChanged && modifierIsDown(code, flags: event.flags) {
                    addMark(for: code, keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType))
                }
            }
        }
        return nil
    }

    private func resetUnlockProgress() {
        escapeCount = 0
        unlockProgress = 0
        lastEscapeTime = -Double.greatestFiniteMagnitude
    }

    private func systemKey(from event: CGEvent) -> (keyboardKeyCode: Int64?, isDown: Bool, isRepeat: Bool)? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        switch Int(nsEvent.subtype.rawValue) {
        case 8:
            let raw = UInt32(truncatingIfNeeded: nsEvent.data1)
            let state = (raw >> 8) & 0xff
            guard state == 10 || state == 11 else { return nil }
            return (KeyboardPosition.functionKeyCode(forSystemKey: Int64((raw >> 16) & 0xffff)),
                    state == 10, raw & 1 != 0)
        case 1:
            return (nil, true, false)
        default:
            return nil
        }
    }

    private func modifierIsDown(_ code: Int64, flags: CGEventFlags) -> Bool {
        switch code {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 57: return flags.contains(.maskAlphaShift)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    private func mouseButton(type: CGEventType, event: CGEvent) -> (number: Int64, down: Bool)? {
        switch type {
        case .leftMouseDown: return (0, true)
        case .leftMouseUp: return (0, false)
        case .rightMouseDown: return (1, true)
        case .rightMouseUp: return (1, false)
        case .otherMouseDown: return (event.getIntegerValueField(.mouseEventButtonNumber), true)
        case .otherMouseUp: return (event.getIntegerValueField(.mouseEventButtonNumber), false)
        default: return nil
        }
    }

    private func isPointerEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
             .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private func requestUnlock() {
        guard tap != nil else { return }
        unlockPending = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.unlockPending else { return }
            self.heldButtons.removeAll()
            self.finishUnlock()
        }
        unlockDeadline?.cancel()
        unlockDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseWaitLimit, execute: work)
        if heldButtons.isEmpty { DispatchQueue.main.async { self.finishUnlock() } }
    }

    private func finishUnlock() {
        guard tap != nil else { return }
        unlockDeadline?.cancel()
        unlockDeadline = nil
        unlockPending = false
        ambientTask?.cancel()
        ambientTask = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        NSApp.presentationOptions = []
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSApp.terminate(nil)
    }

    private func addMark(for keyCode: Int64, keyboardType: Int64) {
        let point = KeyboardPosition.point(for: keyCode, keyboardType: keyboardType)
        let now = ProcessInfo.processInfo.systemUptime
        let continuesBurst = now - lastStampTime <= Self.burstWindow && !activeBurstMarkIDs.isEmpty
        if continuesBurst {
            burstLevel = min(burstLevel + 1, Self.maximumBurstLevel)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) {
                for index in marks.indices where activeBurstMarkIDs.contains(marks[index].id) {
                    marks[index].flurryLevel = burstLevel
                    marks[index].size = min(marks[index].baseSize * burstScale, 540)
                    if burstLevel == 3 || burstLevel == 5 {
                        marks[index].particles += makeFlurryParticles(color: marks[index].color,
                                                                       count: Int.random(in: 2...4))
                    }
                }
            }
        } else {
            activeBurstMarkIDs.removeAll()
            burstLevel = 1
        }
        lastStampTime = now
        nextAmbientEventTime = now + Double.random(in: 9...15)
        let isLeftSide = point.x <= 0.5
        let imageIndex = Int.random(in: 0...1) * 2 + (isLeftSide ? 1 : 0)
        let color = colors.randomElement() ?? .pink
        nextMarkID += 1
        let id = nextMarkID
        let baseSize = CGFloat.random(in: 155...330)
        let particles = burstLevel >= 3
            ? makeFlurryParticles(color: color, count: Int.random(in: 2...4))
            : []
        marks.append(SplashMark(id: id,
                                x: min(max(point.x + CGFloat.random(in: -0.012...0.012), 0), 1),
                                y: min(max(point.y + CGFloat.random(in: -0.012...0.012), 0), 1),
                                color: color,
                                imageIndex: imageIndex,
                                baseSize: baseSize,
                                size: min(baseSize * burstScale, 540),
                                heightScale: CGFloat.random(in: 0.76...1.12),
                                rotation: Double.random(in: -36...36),
                                flurryLevel: burstLevel,
                                particles: particles))
        activeBurstMarkIDs.insert(id)
        if soundEnabled { playfulSound.play(streak: burstLevel) }
        if marks.count > 18 {
            let removedIDs = marks.prefix(marks.count - 18).map(\.id)
            activeBurstMarkIDs.subtract(removedIDs)
            marks.removeFirst(marks.count - 18)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.marks.removeAll { $0.id == id } }
            self.activeBurstMarkIDs.remove(id)
            if self.activeBurstMarkIDs.isEmpty { self.burstLevel = 0 }
        }
    }

    private var burstScale: CGFloat {
        1 + CGFloat(max(burstLevel - 1, 0)) * 0.11
    }

    private func makeFlurryParticles(color: Color, count: Int) -> [PlayfulParticle] {
        let symbols = ["sparkle", "star.fill", "sparkles", "plus", "heart.fill", "circle.fill"]
        return (0..<count).map { _ in
            PlayfulParticle(kind: .sparkle,
                            symbol: symbols.randomElement() ?? "sparkle",
                            xOffset: CGFloat.random(in: -0.64...0.64),
                            yOffset: CGFloat.random(in: -0.64...0.64),
                            size: CGFloat.random(in: 0.07...0.15),
                            rotation: Double.random(in: -45...45),
                            color: colors.randomElement() ?? color)
        }
    }

    private func isPointerOverControls(_ panel: NSPanel) -> Bool {
        guard panel.isVisible, let contentView = panel.contentView else { return false }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        let bounds = contentView.bounds
        let controlsFrame = CGRect(x: bounds.midX - 228, y: bounds.midY - 160,
                                   width: 456, height: 320)
        return controlsFrame.contains(contentPoint)
    }

    private func startAmbientEvents() {
        guard ambientTask == nil else { return }
        nextAmbientEventTime = ProcessInfo.processInfo.systemUptime + Double.random(in: 10...17)
        ambientTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled, let self else { return }
                self.emitAmbientEventIfDue()
            }
        }
    }

    private func emitAmbientEventIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextAmbientEventTime else { return }
        nextAmbientEventTime = now + Double.random(in: 13...24)

        var point = CGPoint(x: CGFloat.random(in: 0.1...0.9), y: CGFloat.random(in: 0.1...0.9))
        for _ in 0..<10 where (0.34...0.66).contains(point.x) && (0.30...0.70).contains(point.y) {
            point = CGPoint(x: CGFloat.random(in: 0.1...0.9), y: CGFloat.random(in: 0.1...0.9))
        }

        let kind = AmbientEffect.Kind.allCases.randomElement() ?? .bubbles
        let particles = makeAmbientParticles(for: kind)
        nextAmbientEffectID += 1
        let id = nextAmbientEffectID
        withAnimation(.easeOut(duration: 0.25)) {
            ambientEffects.append(AmbientEffect(id: id, x: point.x, y: point.y,
                                                size: CGFloat.random(in: 110...175),
                                                rotation: Double.random(in: -30...30),
                                                duration: Double.random(in: 1.8...2.7),
                                                particles: particles))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            withAnimation(.easeOut(duration: 0.35)) {
                self?.ambientEffects.removeAll { $0.id == id }
            }
        }
    }

    private func makeAmbientParticles(for kind: AmbientEffect.Kind) -> [PlayfulParticle] {
        let count = kind == .comet ? 5 : Int.random(in: 5...9)
        return (0..<count).map { index in
            let particleKind: PlayfulParticle.Kind
            let symbol: String
            switch kind {
            case .bubbles:
                particleKind = .bubble
                symbol = ""
            case .confetti:
                particleKind = .confetti
                symbol = ""
            case .comet:
                particleKind = index == 0 ? .sparkle : .confetti
                symbol = index == 0 ? "sparkles" : ""
            }
            return PlayfulParticle(kind: particleKind,
                                   symbol: symbol,
                                   xOffset: CGFloat.random(in: -0.62...0.62),
                                   yOffset: CGFloat.random(in: -0.62...0.62),
                                   size: kind == .comet && index == 0
                                       ? CGFloat.random(in: 0.28...0.38)
                                       : CGFloat.random(in: 0.10...0.24),
                                   rotation: Double.random(in: -70...70),
                                   color: colors.randomElement() ?? .pink)
        }
    }

    private func showOverlays() {
        let screens = NSScreen.screens
        let targets = screens.isEmpty ? [NSRect(x: 0, y: 0, width: 800, height: 600)] : screens.map(\.frame)
        let old = panels
        panels = targets.map { frame in
            if let existing = old.first(where: { $0.frame == frame }) { return existing }
            let panel = UnlockableOverlayPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            // Mission Control space swipes are system gestures; keep the overlay present on every Space.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let host = NSHostingView(rootView: CleaningOverlayView(manager: self))
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            return panel
        }
        old.filter { oldPanel in !panels.contains(where: { $0 === oldPanel }) }.forEach { $0.orderOut(nil) }
        panels.forEach { $0.orderFrontRegardless() }
    }

    func toggleSound() { soundEnabled.toggle() }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showOverlays() }
        }
    }

    private func showAccessibilitySetup() {
        NSApp.setActivationPolicy(.regular)
        NSApp.presentationOptions = []
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Set Up KeySplash"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: AccessibilitySetupView(manager: self))
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showTapFailure() {
        let alert = NSAlert()
        alert.messageText = "Could not lock the keyboard"
        alert.informativeText = "KeySplash could not install its keyboard filter. No overlay was shown, so the keyboard remains usable. Check Accessibility access and try again."
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func showHandprintFailure() {
        let alert = NSAlert()
        alert.messageText = "Handprint artwork is missing"
        alert.informativeText = "Rebuild KeySplash with ./build-app.sh. The keyboard was not locked."
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private struct AccessibilitySetupView: View {
    @ObservedObject var manager: CleaningModeManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("One-time setup")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("Give KeySplash permission to capture key presses")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 21)

            VStack(alignment: .leading, spacing: 15) {
                Text("macOS protects keyboard input. KeySplash needs Accessibility access to block keys during play mode; it does not lock anything until that access is granted.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    SetupStep(number: "1", title: "Open Accessibility settings", detail: "We’ll take you to the right System Settings page.", symbol: "gearshape.fill")
                    SetupStep(number: "2", title: "Enable KeySplash", detail: "Approve the macOS prompt if it appears. If KeySplash isn’t listed, use the + button to add it.", symbol: "switch.2")
                    SetupStep(number: "3", title: "Come back here", detail: "KeySplash checks again automatically and starts as soon as macOS allows it.", symbol: "arrow.uturn.backward")
                }
                .padding(15)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                settingsPath

                Text(manager.setupStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(manager.returnedFromSettings ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button(action: manager.openAccessibilitySettings) {
                        Label("Open Accessibility Settings", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Check Access", action: manager.checkAccessibilityPermission)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                HStack {
                    Button("Quit KeySplash", action: manager.quitSetup)
                        .buttonStyle(.link)
                    Spacer()
                    if manager.returnedFromSettings {
                        Button("Reopen KeySplash", action: manager.restartApplication)
                            .buttonStyle(.link)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(25)
        .frame(width: 540, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var settingsPath: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("LOOK FOR THIS IN SYSTEM SETTINGS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.pink)
                    .frame(width: 23)
                Text("Privacy & Security")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Text("Accessibility").fontWeight(.semibold)
                Spacer(minLength: 3)
                Text("KeySplash")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            .font(.system(size: 12))
            .padding(11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        }
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 21)
        }
    }
}

@MainActor
private final class PlayfulSound {
    private let notes: [AVAudioPlayer] = [440.0, 523.25, 659.25, 783.99, 987.77].compactMap { frequency in
        guard let player = try? AVAudioPlayer(data: PlayfulSound.wave(frequency: frequency)) else { return nil }
        player.volume = 0.14
        player.prepareToPlay()
        return player
    }

    func play(streak: Int) {
        guard !notes.isEmpty else { return }
        let index = streak > 1 ? (streak - 1) % notes.count : Int.random(in: notes.indices)
        notes[index].currentTime = 0
        notes[index].play()
    }

    private static func wave(frequency: Double) -> Data {
        let sampleRate: UInt32 = 22_050
        let frameCount = Int(Double(sampleRate) * 0.12)
        var pcm = Data()
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let envelope = pow(1 - Double(frame) / Double(frameCount), 2)
            let tone = sin(2 * .pi * frequency * time) + 0.22 * sin(2 * .pi * frequency * 2.01 * time)
            let sample = Int16(max(-1, min(1, tone * envelope * 0.34)) * Double(Int16.max))
            appendLittleEndian(sample, to: &pcm)
        }

        var wave = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + pcm.count), to: &wave)
        wave.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &wave)
        appendLittleEndian(UInt16(1), to: &wave)
        appendLittleEndian(UInt16(1), to: &wave)
        appendLittleEndian(sampleRate, to: &wave)
        appendLittleEndian(sampleRate * 2, to: &wave)
        appendLittleEndian(UInt16(2), to: &wave)
        appendLittleEndian(UInt16(16), to: &wave)
        wave.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(pcm.count), to: &wave)
        wave.append(pcm)
        return wave
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

private final class UnlockableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct PlayfulParticle: Identifiable {
    enum Kind { case sparkle, bubble, confetti }

    let id = UUID()
    let kind: Kind
    let symbol: String
    let xOffset: CGFloat
    let yOffset: CGFloat
    let size: CGFloat
    let rotation: Double
    let color: Color
}

struct AmbientEffect: Identifiable {
    enum Kind: CaseIterable { case bubbles, confetti, comet }

    let id: Int
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let rotation: Double
    let duration: Double
    let particles: [PlayfulParticle]
}

struct SplashMark: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let color: Color
    let imageIndex: Int
    let baseSize: CGFloat
    var size: CGFloat
    let heightScale: CGFloat
    let rotation: Double
    var flurryLevel: Int
    var particles: [PlayfulParticle]
}

private struct CleaningOverlayView: View {
    @ObservedObject var manager: CleaningModeManager

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear.ignoresSafeArea()
                ForEach(manager.marks) { mark in
                    ZStack {
                        Handprint(color: mark.color, imageIndex: mark.imageIndex)
                        if mark.flurryLevel >= 3 {
                            ForEach(mark.particles) { particle in
                                ParticleGlyph(particle: particle, size: mark.size * particle.size)
                                    .offset(x: particle.xOffset * mark.size,
                                            y: particle.yOffset * mark.size)
                            }
                        }
                    }
                        .frame(width: mark.size, height: mark.size * mark.heightScale)
                        .rotationEffect(.degrees(mark.rotation))
                        .position(x: mark.x * geometry.size.width, y: mark.y * geometry.size.height)
                        .transition(.scale(scale: 0.45).combined(with: .opacity))
                        .animation(.spring(response: 0.38, dampingFraction: 0.68), value: mark.size)
                        .allowsHitTesting(false)
                }
                ForEach(manager.ambientEffects) { effect in
                    AmbientEffectView(effect: effect, containerSize: geometry.size)
                }
                VStack(spacing: 15) {
                    Image(systemName: "keyboard").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8))
                    Text("Keyboard playtime!").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    Text("Tap keys to make colorful handprints").font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                    HStack(spacing: 9) {
                        ForEach(0..<CleaningModeManager.threshold, id: \.self) { i in
                            Circle().fill(i < manager.unlockProgress ? .white : .white.opacity(0.2)).frame(width: 10, height: 10)
                        }
                    }
                    Button("Unlock") { manager.requestUnlockFromButton() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .buttonStyle(.plain)
                        .padding(.top, 5)
                    HStack(spacing: 10) {
                        Text("or press Esc five times")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.58))
                        Button { manager.toggleSound() } label: {
                            Image(systemName: manager.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(manager.soundEnabled ? "Mute sounds" : "Enable sounds")
                        .help(manager.soundEnabled ? "Mute sounds" : "Enable sounds")
                    }
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                .frame(width: 456, height: 320)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}

private struct ParticleGlyph: View {
    let particle: PlayfulParticle
    let size: CGFloat

    var body: some View {
        Group {
            switch particle.kind {
            case .sparkle:
                Image(systemName: particle.symbol)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(particle.color)
                    .shadow(color: particle.color.opacity(0.55), radius: size * 0.28)
            case .bubble:
                Circle()
                    .fill(particle.color.opacity(0.13))
                    .overlay { Circle().strokeBorder(particle.color.opacity(0.8), lineWidth: max(1.5, size * 0.055)) }
                    .overlay(alignment: .topLeading) {
                        Circle().fill(.white.opacity(0.72))
                            .frame(width: size * 0.2, height: size * 0.2)
                            .padding(size * 0.22)
                    }
                    .shadow(color: particle.color.opacity(0.3), radius: size * 0.12)
            case .confetti:
                Capsule().fill(particle.color.gradient)
                    .shadow(color: particle.color.opacity(0.35), radius: size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(particle.rotation))
    }
}

private struct AmbientEffectView: View {
    let effect: AmbientEffect
    let containerSize: CGSize
    @State private var drifting = false

    var body: some View {
        ZStack {
            ForEach(effect.particles) { particle in
                ParticleGlyph(particle: particle, size: effect.size * particle.size)
                    .offset(x: particle.xOffset * effect.size,
                            y: particle.yOffset * effect.size)
            }
        }
        .frame(width: effect.size * 2, height: effect.size * 2)
        .rotationEffect(.degrees(effect.rotation))
        .scaleEffect(drifting ? 1.18 : 0.72)
        .opacity(drifting ? 0.04 : 0.86)
        .position(x: effect.x * containerSize.width, y: effect.y * containerSize.height)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: effect.duration)) { drifting = true }
        }
    }
}

private extension CleaningModeManager {
    func requestUnlockFromButton() { requestUnlock() }
}

private struct Handprint: View {
    let color: Color
    let imageIndex: Int

    var body: some View {
        if HandprintLibrary.variants.indices.contains(imageIndex) {
            Image(decorative: HandprintLibrary.variants[imageIndex], scale: 1)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(color)
                .scaledToFit()
                .shadow(color: color.opacity(0.45), radius: 16)
                .blendMode(.screen)
        }
    }
}

private enum HandprintLibrary {
    static let variants = loadVariants()

    private static func loadVariants() -> [CGImage] {
        guard let url = Bundle.main.url(forResource: "handprint-options", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let spriteSheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let alphaMask = makeAlphaMask(from: spriteSheet) else { return [] }

        let halfWidth = CGFloat(alphaMask.width) / 2
        let halfHeight = CGFloat(alphaMask.height) / 2
        return (0..<4).compactMap { index in
            let column = index % 2
            let row = index / 2
            return alphaMask.cropping(to: CGRect(x: CGFloat(column) * halfWidth,
                                                 y: CGFloat(row) * halfHeight,
                                                 width: halfWidth, height: halfHeight))
        }
    }

    private static func makeAlphaMask(from image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = input
        filter.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: -0.2126, y: -0.7152, z: -0.0722, w: 0)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

private enum KeyboardPosition {
    // Coordinates are physical key centers normalized to the full ANSI keyboard bounds.
    // QWERTY/QWERTZ/AZERTY only change legends; CGEvent keycodes keep the physical positions.
    private static let ansi: [Int64: CGPoint] = [
        53:p(0.02,0.00), 122:p(0.12,0.00), 120:p(0.19,0.00), 99:p(0.26,0.00), 118:p(0.33,0.00),
        96:p(0.44,0.00), 97:p(0.51,0.00), 98:p(0.62,0.00), 100:p(0.69,0.00), 101:p(0.80,0.00),
        109:p(0.87,0.00), 103:p(0.94,0.00), 111:p(0.99,0.00),

        50:p(0.02,0.20), 18:p(0.10,0.20), 19:p(0.17,0.20), 20:p(0.24,0.20), 21:p(0.31,0.20),
        23:p(0.38,0.20), 22:p(0.45,0.20), 26:p(0.52,0.20), 28:p(0.59,0.20), 25:p(0.66,0.20),
        29:p(0.73,0.20), 27:p(0.80,0.20), 24:p(0.87,0.20), 51:p(0.97,0.20),

        48:p(0.02,0.40), 12:p(0.11,0.40), 13:p(0.18,0.40), 14:p(0.25,0.40), 15:p(0.32,0.40),
        17:p(0.39,0.40), 16:p(0.46,0.40), 32:p(0.53,0.40), 34:p(0.60,0.40), 31:p(0.67,0.40),
        35:p(0.74,0.40), 33:p(0.81,0.40), 30:p(0.88,0.40), 42:p(0.97,0.40),

        57:p(0.02,0.60), 0:p(0.14,0.60), 1:p(0.21,0.60), 2:p(0.28,0.60), 3:p(0.35,0.60),
        5:p(0.42,0.60), 4:p(0.49,0.60), 38:p(0.56,0.60), 40:p(0.63,0.60), 37:p(0.70,0.60),
        41:p(0.77,0.60), 39:p(0.84,0.60), 36:p(0.97,0.60),

        56:p(0.02,0.80), 6:p(0.18,0.80), 7:p(0.25,0.80), 8:p(0.32,0.80), 9:p(0.39,0.80),
        11:p(0.46,0.80), 45:p(0.53,0.80), 46:p(0.60,0.80), 43:p(0.67,0.80), 47:p(0.74,0.80),
        44:p(0.81,0.80), 60:p(0.97,0.80),

        63:p(0.02,1.00), 59:p(0.10,1.00), 58:p(0.22,1.00), 55:p(0.35,1.00), 49:p(0.50,1.00),
        54:p(0.67,1.00), 61:p(0.80,1.00), 62:p(0.92,1.00),
        126:p(0.94,0.74), 123:p(0.88,0.87), 124:p(0.98,0.87), 125:p(0.94,1.00)
    ]

    private static let iso: [Int64: CGPoint] = [
        10:p(0.14,0.80), 6:p(0.23,0.80), 7:p(0.30,0.80), 8:p(0.37,0.80), 9:p(0.44,0.80),
        11:p(0.51,0.80), 45:p(0.58,0.80), 46:p(0.65,0.80), 43:p(0.72,0.80), 47:p(0.79,0.80),
        44:p(0.86,0.80), 60:p(0.97,0.80)
    ]

    private static let jis: [Int64: CGPoint] = [
        93:p(0.92,0.20), 94:p(0.86,0.80), 102:p(0.37,1.00), 104:p(0.63,1.00),
        6:p(0.17,0.80), 7:p(0.24,0.80), 8:p(0.31,0.80), 9:p(0.38,0.80), 11:p(0.45,0.80),
        45:p(0.52,0.80), 46:p(0.59,0.80), 43:p(0.66,0.80), 47:p(0.73,0.80), 44:p(0.80,0.80),
        49:p(0.50,1.00)
    ]

    private static let functionPositions: [Int64: Int64] = [
        0:111, 1:103, 2:120, 3:122, 7:109, 13:118, 16:100, 17:101,
        18:98, 19:101, 20:98, 21:97, 22:96, 23:96, 8:126, 9:125
    ]

    static func functionKeyCode(forSystemKey keyCode: Int64) -> Int64? {
        functionPositions[keyCode]
    }

    static func point(for keyCode: Int64, keyboardType: Int64) -> CGPoint {
        let layout = KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType))
        let overrides: [Int64: CGPoint]
        switch layout {
        case UInt32(kKeyboardISO): overrides = iso
        case UInt32(kKeyboardJIS): overrides = jis
        default: overrides = [:]
        }
        return overrides[keyCode] ?? ansi[keyCode] ?? p(0.5, 0.5)
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
}
