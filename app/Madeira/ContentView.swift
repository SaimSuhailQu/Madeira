import SwiftUI
import UIKit
import QuartzCore
import Metal
import os.log
import UniformTypeIdentifiers

// 2026-07-03 window-hosted Metal layer.
//
// The presenting CAMetalLayer must NOT be a SwiftUI-hosted view's backing
// layer: on iOS 26/27, SwiftUI's hosting intermittently routes such layers
// through an indirect/snapshot path where direct Metal presentations are
// silently dropped — presented drawables complete with presentedTime==0
// (measured), the screen freezes on stale content, and only full-tree
// re-renders (screenshots) reveal new frames. Which path a given run gets
// appeared random — the "sometimes rendering starts at present #9,
// sometimes never" lottery.
//
// So the layer now lives in MetalHostView, a raw UIView added directly to
// the UIWindow (classic game setup, no SwiftUI management). The SwiftUI-
// hosted MetalBackedView remains as a transparent layout placeholder that
// tracks geometry and handles touch input. The host view sits on top of
// the window but has interaction disabled, so touches fall through to the
// SwiftUI hierarchy (and thus to the placeholder's touch handlers).

/// Raw window-level host for the presenting CAMetalLayer.
final class MetalHostView: UIView {
    // Process-lifetime singleton. The CAMetalLayer is registered with DXMT's
    // swapchain exactly once; if the host were recreated on view teardown
    // (rotation, re-attach) DXMT would keep presenting to the DEAD layer —
    // black surface both ways (2026-07-05 landscape regression). One host,
    // one layer, forever; only its FRAME is re-parented/resized.
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // touches fall through to SwiftUI
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // 2026-07-03 MeloNX trick: displaySyncEnabled is macOS-public but
        // exists as PRIVATE API on iOS. Disabling it takes our presents out
        // of the display-sync scheduling machinery — the thing that has been
        // silently dropping them (presentedTime==0 on all but occasional
        // frames) at our sub-1Hz game present cadence. MeloNX (shipping
        // Switch emulator) sets exactly this pair on its layer.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
            LogStore.shared.log("MetalLayer: displaySyncEnabled=false (private API, MeloNX pattern)")
        }
        /* ml651: was hardcoded 60, which contradicted everything around it —
         * FPSOverlay asks the display link for CAFrameRateRange(preferred: 120)
         * while this declared the surface a 60Hz one. Track the screen instead.
         *
         * ⚠️ HYPOTHESIS, NOT A DIAGNOSIS. displaySyncEnabled=false directly above
         * takes our presents out of display-sync scheduling, so this nominal
         * value may well be inert. It is one line and it removes a genuine
         * contradiction; if the A/B shows nothing, the cap is elsewhere and we
         * have eliminated it rather than argued about it. */
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) {
            let hz = UIScreen.main.maximumFramesPerSecond
            metalLayer.perform(fpsSel, with: hz as NSNumber)
            LogStore.shared.log("MetalLayer: ml651 nominalFPS=\(hz) (was hardcoded 60; "
                                + "display link asks preferred=120)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        // Set once so DXMT's swapchain setup never blocks on a zero-sized
        // layer. After this, DXMT's setProps is the ONLY drawableSize
        // writer — per-layout rewrites from the app were a second writer
        // fighting it (pool churn on every SwiftUI layout pass).
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// SwiftUI-hosted placeholder: geometry + touch input only.
final class MetalBackedView: UIView {
    private static var layerRegistered = false

    // Hardware keyboard bridge: the view becomes first responder so the iOS
    // software keyboard appears, and each typed character is forwarded to
    // Wine as a virtual-key sequence (winios_post_key → send_hardware_message
    // → WM_KEYDOWN/WM_CHAR). Lets the user type into Windows dialogs (e.g.
    // Run) directly instead of relying on the browse list.
    static weak var keyboardTarget: MetalBackedView?
    override var canBecomeFirstResponder: Bool { true }
    static func toggleKeyboard() {
        guard let v = keyboardTarget else { return }
        if v.isFirstResponder { v.resignFirstResponder() }
        else { v.becomeFirstResponder() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Multi-touch REQUIRED: with it off, a fast double-tap's second
        // touch (landing before the first lift is processed) is silently
        // swallowed — drag-arm never fired (2026-07-06). Two-finger
        // scroll/right-click need it too.
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Visibility-stall postmortem (2026-07-03): the intermittent "presents
    // count but the screen stays black until a bg/fg or screenshot" state
    // was probed exhaustively — drawable leaks, present pacing, panel idle,
    // SwiftUI hosting, display-sync, CADisplayLink, transaction nudges and
    // view re-attach kicks were all eliminated (none changed it; only true
    // scene-level lifecycle events land pending frames, ~1-2 each). The one
    // robust correlate is present cadence: 60 FPS content always displays,
    // ~1 FPS content mostly doesn't. Resolution path: raise game FPS (perf
    // work), with a steady-rate re-present in DXMT as fallback insurance.

    /// Largest 4:3 rect (the 1024×768 logical surface's aspect) that fits
    /// centered in our bounds. The window-level host view gets THIS frame,
    /// not our full bounds — otherwise landscape stretches the game to the
    /// display edges (2026-07-05). Touch mapping uses the same rect so
    /// letterboxing never skews input.
    private func gameRect() -> CGRect {
        let gw: CGFloat = 1024, gh: CGFloat = 768
        let scale = min(bounds.width / gw, bounds.height / gh)
        let w = gw * scale, h = gh * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                      width: max(w, 1), height: max(h, 1))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { return }   // detach: leave the host be
        MetalBackedView.keyboardTarget = self  // keyboard button targets the live view
        // SwiftUI ancestors attach gesture recognizers that can delay or
        // cancel raw touch delivery (double-tap timing is exactly what
        // they punish). Defuse them for our subtree.
        var v: UIView? = self
        while let s = v {
            s.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            v = s.superview
        }
        let host = MetalHostView.shared
        if host.superview !== w {
            host.removeFromSuperview()
            w.addSubview(host)
        }
        host.frame = convert(gameRect(), to: w)
        // S2 desktop mode: the winios compositor renders the wine virtual
        // desktop aspect-fit inside THIS placeholder's area, exactly like
        // the games' Metal layer — never over the whole phone screen.
        let full = convert(bounds, to: w)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
            LogStore.shared.log("MetalLayer registered with DXMT shim (window-hosted singleton)", level: .success)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let w = window {
            MetalHostView.shared.frame = convert(gameRect(), to: w)
            let full = convert(bounds, to: w)
            winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        }
    }

    // Map touch point in view-local UI points to the 1024×768 logical
    // surface DXMT swapchains use, then post to winios.drv. Coordinates
    // are relative to the aspect-fit gameRect (letterbox borders clamp).
    private func mapTouch(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let r = gameRect()
        let x = Int32(min(max((p.x - r.minX) * 1024 / r.width, 0), 1023))
        let y = Int32(min(max((p.y - r.minY) * 768 / r.height, 0), 767))
        return (x, y)
    }

    // ==================================================================
    // S2 desktop mode: trackpad-style pointer.
    //   one finger move       — cursor moves relative (like a laptop pad)
    //   single tap            — left click
    //   double tap            — double click (two rapid clicks)
    //   double tap + hold     — drag (button held while moving), lift = drop
    //   two-finger drag       — scroll wheel
    //   two-finger tap        — right click
    // Cursor position lives here (desktop px); wine + the rendered arrow
    // follow via winios_pointer / winios_cursor_move.
    // ==================================================================
    private static var cursor = CGPoint(x: 480, y: 270)
    private var lastPanPoint = CGPoint.zero
    private var touchStartPoint = CGPoint.zero
    private var touchStartTime: TimeInterval = 0
    private var movedBeyondSlop = false
    private var dragActive = false
    private var dragTouch: UITouch?          // the finger that owns the drag
    private var touchGeneration = 0          // invalidates pending long-press timers
    private var twoFingerActive = false
    private var twoFingerMoved = false
    private var twoFingerStartTime: TimeInterval = 0
    private var lastTwoFingerY: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    // ml641: relative motion is scaled by a float sensitivity, so the integer
    // delta we hand to wine loses a fraction every event. At low sensitivity
    // that truncation is the whole signal — carry the remainder or slow drags
    // simply do nothing.
    private var relCarryX: CGFloat = 0
    private var relCarryY: CGFloat = 0

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

    private var desktopMode: Bool {
        guard let v = getenv("MADEIRA_DESKTOP") else { return false }
        return v.pointee == 49  // '1'
    }
    private func envInt(_ name: String, _ def: Int) -> Int {
        guard let v = getenv(name), let i = Int(String(cString: v)) else { return def }
        return i
    }
    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(Self.cursor.x), Int32(Self.cursor.y), flags, UInt32(bitPattern: data))
    }
    private func avgPoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches { let p = t.location(in: self); x += p.x; y += p.y }
        let n = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }
    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_down(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        let active = activeTouches(event)
        touchGeneration += 1
        if active.count >= 2 {
            twoFingerActive = true
            twoFingerMoved = false
            twoFingerStartTime = now
            lastTwoFingerY = avgPoint(active).y
            scrollAccum = 0
            // a drag started by the first finger stays active; harmless
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        touchStartPoint = p
        lastPanPoint = p
        touchStartTime = now
        movedBeyondSlop = false
        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift
        // long-press → drag: hold still for 0.5s, haptic confirms, then move
        // the window; release drops. (Replaced double-tap-hold — it raced
        // Windows' double-click detection: wine saw WM_LBUTTONDBLCLK.)
        let gen = touchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.touchGeneration == gen, !self.dragActive,
                  !self.movedBeyondSlop, !self.twoFingerActive,
                  // ml643: in mouse-look the finger is the CAMERA, not a pointer.
                  // Holding still to line up a shot must not press the mouse.
                  !InputSettings.shared.relative else { return }
            self.dragActive = true
            self.dragTouch = t
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fputs("[trackpad] long-press drag armed\n", stderr)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_move(x, y)
            return
        }
        let active = activeTouches(event)
        if twoFingerActive {
            guard active.count >= 2 else { return }
            let avg = avgPoint(active)
            let dy = avg.y - lastTwoFingerY
            lastTwoFingerY = avg.y
            if abs(dy) > 2 { twoFingerMoved = true }
            scrollAccum += dy
            // 14pt of finger travel = one wheel notch. ml641 flipped the sign:
            // on a touchscreen the content follows the finger, so dragging UP
            // scrolls DOWN through the document. It was mouse-wheel sense before.
            while scrollAccum <= -14 { scrollAccum += 14; postPointer(F_WHEEL, data: -120) }
            while scrollAccum >= 14 { scrollAccum -= 14; postPointer(F_WHEEL, data: 120) }
            return
        }
        let t: UITouch
        if dragActive, let d = dragTouch {
            guard touches.contains(d) else { return }  // only the old tap finger moved
            t = d
        } else {
            guard let f = touches.first else { return }
            t = f
        }
        let p = t.location(in: self)
        let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
        lastPanPoint = p
        if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }

        /* ml641 RELATIVE (mouse-look) MODE.
         *
         * Absolute input is what made the camera spin. We post a POSITION; wine
         * turns it into the delta the game reads as
         *     x - desktop_shm->cursor.x            (queue_ios.c:2290)
         * A game that locks the cursor calls ClipCursor, and update_desktop_cursor_pos
         * then CLAMPS desktop_shm->cursor into that rect, pinning it. Our own
         * Self.cursor keeps wandering across the full 1024x768, so the subtraction
         * yields (wandering - pinned): a huge delta that never converges and is
         * re-sent on every event. Spin rate depends on WHERE the finger is, not how
         * fast it moves.
         *
         * Posting device motion instead makes that impossible to reproduce: wine
         * computes cursor.x + dx, so the delta is exactly dx no matter what the
         * game does to the cursor. No F_ABS, and Self.cursor is deliberately not
         * touched — in this mode it has no meaning.
         *
         * Sign follows PUBG/Fortnite: drag right -> view turns right -> the world
         * slides left, so a target to the RIGHT of the crosshair is pulled onto it
         * by dragging RIGHT. That is the same sign as a mouse. Negate both terms
         * for content-drag (finger-follows-world) feel. */
        if InputSettings.shared.relative {
            let sens = CGFloat(InputSettings.shared.sensRel)
            relCarryX += dx * sens
            relCarryY += dy * sens
            let ix = Int32(max(-30000, min(30000, relCarryX)))
            let iy = Int32(max(-30000, min(30000, relCarryY)))
            relCarryX -= CGFloat(ix)
            relCarryY -= CGFloat(iy)
            if ix != 0 || iy != 0 { winios_pointer(ix, iy, F_MOVE, 0) }
            return
        }

        let sens = CGFloat(InputSettings.shared.sensAbs)   // desktop px per view pt
        let maxX = CGFloat(envInt("MADEIRA_SCREEN_W", 1024) - 1)
        let maxY = CGFloat(envInt("MADEIRA_SCREEN_H", 768) - 1)
        Self.cursor.x = min(max(Self.cursor.x + dx * sens, 0), maxX)
        Self.cursor.y = min(max(Self.cursor.y + dy * sens, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {
            if activeTouches(event).isEmpty {
                if !twoFingerMoved && now - twoFingerStartTime < 0.40
                    && !InputSettings.shared.relative {   // ml643: see touchesBegan
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                twoFingerActive = false
            }
            return
        }
        touchGeneration += 1   // cancel any pending long-press
        if dragActive {
            if let d = dragTouch, !touches.contains(d) {
                fputs("[trackpad] ended: non-drag finger up (drag continues)\n", stderr)
                return
            }
            fputs("[trackpad] ended: drag drop\n", stderr)
            postPointer(F_LUP)
            dragActive = false
            dragTouch = nil
            return
        }
        // stationary release before the 0.5s drag threshold = click.
        // ml643: NOT in relative mode — every small aim adjustment would fire the
        // weapon. Left/right click are on-screen buttons there instead.
        if !movedBeyondSlop && now - touchStartTime < 0.5 && !InputSettings.shared.relative {
            fputs("[trackpad] ended: click\n", stderr)
            postPointer(F_LDOWN)
            postPointer(F_LUP)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        fputs("[trackpad] CANCELLED (dragActive=\(dragActive))\n", stderr)
        touchGeneration += 1
        if dragActive { postPointer(F_LUP); dragActive = false }
        dragTouch = nil
        twoFingerActive = false
    }
}

/// Arrow-key button with press/hold/release semantics. DragGesture with
/// zero minimum distance fires onChanged at touch-down (key down once)
/// and onEnded at lift (key up) — unlike Button, which only taps.
struct HoldKeyView: View {
    let label: String
    let vk: Int32
    var big = false   // landscape D-pad: thumb-sized
    @State private var isDown = false

    var body: some View {
        Text(label)
            .font(.system(size: big ? 22 : 14, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .frame(minWidth: big ? 56 : 34, minHeight: big ? 56 : 30)
            .background(Color.white.opacity(isDown ? 0.35 : 0.15))
            .cornerRadius(big ? 12 : 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown {
                            isDown = true
                            winios_post_key(vk, 1)
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        winios_post_key(vk, 0)
                    }
            )
    }
}

/// Shared state for the expanded thumbstick pad. The pad cannot be drawn by
/// SwiftUI in place: the game surface is a raw window-level UIView
/// (MetalHostView.shared) sitting ABOVE the entire SwiftUI hierarchy, so a
/// SwiftUI pad centred on the key row gets sliced off wherever it overlaps —
/// no zIndex can fix that, because zIndex only orders siblings *within*
/// SwiftUI. So the pad is hosted in the window too, added after (and thus
/// above) the Metal view, and driven from the SwiftUI button through this.
final class JoystickPadState: ObservableObject {
    static let shared = JoystickPadState()
    @Published var held = false
    @Published var dir: Int = -1
    @Published var center: CGPoint = .zero      // window coordinates
    /// ml641: driven by the pointer panel. The pad is NOT a sibling of the key
    /// row — it lives in its own UIWindow one level up (that is the whole point
    /// of this class), so the row's .transition(.opacity) cannot reach it and it
    /// stayed visible while every other button faded. It has to fade itself.
    @Published var hidden = false
    @Published var inFullscreen = false
}

/// Window-level host for the pad. Transparent and non-interactive: the
/// SwiftUI button keeps the gesture, this only draws.
enum JoystickPadHost {
    /// Own UIWindow, one level above the app's. Being a sibling subview of
    /// MetalHostView is NOT enough: that view re-adds itself to the window on
    /// every didMoveToWindow (rotation, re-attach) and DXMT/CoreAnimation can
    /// reorder around it, so any subview ordering we impose is only true until
    /// the next layout. A higher windowLevel cannot be undone by anything
    /// inside the app window, so the pad is unconditionally on top.
    ///
    /// Deliberately NOT solved by changing the game surface: the CAMetalLayer
    /// is window-level precisely because SwiftUI hosting silently dropped
    /// presents on iOS 26/27 (see MetalHostView) — that is a rendering
    /// correctness fix and must not be traded away for z-ordering.
    private static var overlay: PassthroughWindow?

    static func attach(to scene: UIWindowScene) {
        if overlay == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 100
            w.backgroundColor = .clear
            w.isHidden = false                 // never becomes key: see PassthroughWindow
            let host = UIHostingController(rootView: JoystickPadOverlay())
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            overlay = w
        }
        overlay?.frame = scene.coordinateSpace.bounds
    }
}

/// Transparent, fully click-through window: hitTest always returns nil, so
/// touches fall through to the app window underneath and the pad can never
/// steal input from the game surface or the SwiftUI controls.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The expanded pad, drawn in window space at the button's location.
struct JoystickPadOverlay: View {
    @ObservedObject private var s = JoystickPadState.shared

    var body: some View {
        GeometryReader { _ in
            // THE one and only joystick face — idle ring and expanded pad are
            // the same view, never two that swap. That identity is what makes
            // it seamless: the diameter and the knob offset are plain animated
            // properties, so releasing lets the knob spring back to centre and
            // keep wiggling after the ring has already shrunk. Two faces
            // cross-fading (one in the button, one here) cannot do that — the
            // wiggle dies with the copy that gets faded out.
            //
            // Fixed-size box at a CONSTANT offset. Deliberately not
            // .position() + .transition(.scale): .position expands the view to
            // fill the parent (so a .center anchor means mid-screen), and an
            // offset that changes in the same transaction as `held` gets
            // animated too — which is what made the pad fly in from the top.
            // Here the only animatable quantities belong to the face itself.
            JoystickFace(held: s.held, dir: s.dir)
                .frame(width: JoystickFace.padRadius * 2,
                       height: JoystickFace.padRadius * 2)
                .offset(x: s.center.x - JoystickFace.padRadius,
                        y: s.center.y - JoystickFace.padRadius)
                .opacity(s.center == .zero ? 0 : 1)
        }
        // MUST ignore the safe area. s.center comes from the button's .global
        // frame, which is measured from the WINDOW origin; without this the
        // overlay's hosting view is inset by the safe area, the offset above
        // is measured from below the status bar, and the pad lands ~59pt too
        // low — roughly one pad radius, which is exactly why it appeared to
        // sit under the game strip instead of centred on the button.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity((s.hidden || s.inFullscreen) ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: s.hidden || s.inFullscreen)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: s.held)
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: s.dir)
    }
}

/// The joystick face itself, shared by the in-row idle ring and the expanded
/// window-level pad so both look identical and animate the same way.
struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    private var expanded: Bool { held || alwaysExpanded }

    static let idleDiameter: CGFloat = 22
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    private var interior: some View {
        GlassShape(circle: true)
    }

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard dir >= 0, expanded else { return .zero }
        let travel = d * knobTravelRatio
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        return ZStack {
            interior
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .offset(knobOffset(d))
        }
        .frame(width: d, height: d)
    }
}

/// On-screen thumbstick. Idle it is a key-sized ring with a white knob;
/// press and hold and it expands into a pad you can steer. Travel snaps to
/// eight d-pad directions, each mapped to the arrow keys Windows games
/// already understand — diagonals simply hold two keys at once — so this
/// needs no new input path: it posts through the same winios_post_key queue
/// as the key buttons, and key state is edge-triggered (only the keys that
/// actually changed are sent on each snap).
///
/// The pad expands DOWNWARD. It must never grow up into the game strip:
/// that surface is a raw window-level UIView (MetalHostView.shared) drawn
/// over SwiftUI, so anything overlapping it is simply covered.
struct JoystickKeyView: View {
    @State private var held = false
    @State private var dir: Int = -1        // -1 = centred, else 0=up then clockwise
    @State private var center: CGPoint = .zero
    @State private var hosted = false       // overlay window up: it draws the face

    private let deadzone: CGFloat = 14      // pt of travel before a direction registers

    private let vkUp: Int32 = 0x26, vkRight: Int32 = 0x27
    private let vkDown: Int32 = 0x28, vkLeft: Int32 = 0x25

    private func keys(for d: Int) -> [Int32] {
        switch d {
        case 0: return [vkUp]
        case 1: return [vkUp, vkRight]
        case 2: return [vkRight]
        case 3: return [vkDown, vkRight]
        case 4: return [vkDown]
        case 5: return [vkDown, vkLeft]
        case 6: return [vkLeft]
        case 7: return [vkUp, vkLeft]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is — never a blanket
    /// release/re-press, which would make a held direction stutter as the
    /// thumb wanders inside one sector.
    private func apply(_ next: Int) {
        guard next != dir else { return }
        let old = Set(keys(for: dir)), new = Set(keys(for: next))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        dir = next
        JoystickPadState.shared.dir = next
    }

    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < deadzone { return -1 }
        // Screen y grows downward; measure clockwise from "up".
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    var body: some View {
        // The idle ring lives in the row (inset inside the 34x30 button so it
        // has breathing room). The EXPANDED pad is drawn by the window-level
        // host at this same centre — see JoystickPadState — so it springs out
        // of the button in place and is never clipped by the game surface.
        Color.clear
            .frame(width: 34, height: 30)
            .background(Color.white.opacity(held ? 0.30 : 0.15))
            .cornerRadius(6)
            .overlay { if !hosted { JoystickFace(held: false, dir: -1) } }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        center = CGPoint(x: geo.frame(in: .global).midX,
                                         y: geo.frame(in: .global).midY)
                        JoystickPadState.shared.center = center
                        if let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first {
                            JoystickPadHost.attach(to: scene)
                            hosted = true
                        }
                    }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        center = CGPoint(x: f.midX, y: f.midY)
                        JoystickPadState.shared.center = center
                    }
                }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: held)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !held {
                            held = true
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                JoystickPadHost.attach(to: scene)
                            }
                            JoystickPadState.shared.center = center
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                JoystickPadState.shared.held = true
                            }
                        }
                        apply(snap(g.translation))
                    }
                    .onEnded { _ in
                        apply(-1)                        // releases every held arrow
                        held = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            JoystickPadState.shared.held = false
                        }
                    }
            )
            .opacity(JoystickPadState.shared.inFullscreen ? 0 : 1)
    }
}

// SwiftUI wrapper around the placeholder view.
// iOS software-keyboard → Wine key events. Each character is mapped to a
// US-layout virtual-key (+ shift where needed) and posted as a down/up pair;
// the message queue's ToUnicode then produces the right WM_CHAR. Paths need
// the full symbol set (":" "\" "-" "." "_"), so the table is comprehensive.
extension MetalBackedView: UIKeyInput {
    var hasText: Bool { false }

    // US-keyboard VK + shift for a character. Returns nil for chars we can't map.
    private static func vkForChar(_ ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (0x0D, false) }   // VK_RETURN
        if ch == "\t" { return (0x09, false) }                 // VK_TAB
        if ch == " " { return (0x20, false) }                  // VK_SPACE
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return (Int32(up), ch.isUppercase)                 // VK_A..VK_Z
        }
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            return (Int32(a), false)                           // VK_0..VK_9 (unshifted)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[ch]
    }

    func insertText(_ text: String) {
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            if shift { winios_post_key(0x10, 1) }   // VK_SHIFT down
            winios_post_key(vk, 1)
            winios_post_key(vk, 0)
            if shift { winios_post_key(0x10, 0) }    // VK_SHIFT up
        }
    }

    func deleteBackward() {
        winios_post_key(0x08, 1)   // VK_BACK down
        winios_post_key(0x08, 0)
    }

    // Traits: keep iOS from rewriting path characters.
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}

/// Pointer settings, persisted to the app container.
///
/// ml641. Two independent sensitivities, because the two modes mean different
/// things and a single slider would fight itself:
///   • absolute  — trackpad gain, desktop px per view pt. This IS the old
///     hardcoded `sens = 2.0`, so the default reproduces today's desktop feel
///     exactly.
///   • relative  — mouse counts per view pt for mouse-look. What the right value
///     is depends on the GAME's own sensitivity and FOV, which we cannot see, so
///     it has to be calibrated by hand once. See the comment in touchesMoved.
///
/// Stored as JSON in Documents/ rather than UserDefaults: that is the container
/// we already know survives reinstall (verified), and it can be pulled and
/// edited with the same devicectl command we use for the log.
final class InputSettings: ObservableObject {
    static let shared = InputSettings()

    @Published var relative: Bool  = false { didSet { save() } }
    @Published var sensAbs:  Double = 2.0  { didSet { save() } }
    @Published var sensRel:  Double = 2.0  { didSet { save() } }
    /// ml649: heavy diagnostics. Default OFF so the shipped default is the fast
    /// path; flip it on only when a run needs to be explainable.
    @Published var diagnostics = false { didSet { madeira_set_diag_enabled(diagnostics ? 1 : 0); save() } }

    /// didSet fires for assignments made in init() because the properties are
    /// already initialised by then; without this the first launch would write
    /// the defaults back over a file it had only half-read.
    private var loading = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-input.json")
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            relative = j["relative"] as? Bool   ?? false
            sensAbs  = j["sensAbs"]  as? Double ?? 2.0
            sensRel  = j["sensRel"]  as? Double ?? 2.0
            diagnostics = j["diagnostics"] as? Bool ?? false
        }
        loading = false
        madeira_set_diag_enabled(diagnostics ? 1 : 0)   // push the restored value down
    }

    private func save() {
        guard !loading else { return }
        let j: [String: Any] = ["relative": relative, "sensAbs": sensAbs, "sensRel": sensRel, "diagnostics": diagnostics]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

struct MadeiraMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalBackedView {
        return MetalBackedView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    func updateUIView(_ uiView: MetalBackedView, context: Context) {}
}

/// Animated neon-rainbow title view for portrait and landscape with black controller badge and PS5 styling
struct AnimatedNeonRainbowTitle: View {
    var size: CGFloat = 20
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            // Sleek black badge with PS5 / DualSense controller & PlayStation symbols
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: size * 1.5, height: size * 1.5)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.cyan, .purple, .pink, .blue, .cyan],
                                    startPoint: UnitPoint(x: phase - 1, y: 0),
                                    endPoint: UnitPoint(x: phase, y: 1)
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: .cyan.opacity(0.6), radius: 4, x: 0, y: 0)

                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: size * 0.85, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.pink, .purple, .cyan, .green, .yellow, .orange, .pink],
                            startPoint: UnitPoint(x: phase - 1, y: 0),
                            endPoint: UnitPoint(x: phase, y: 1)
                        )
                    )
                    .shadow(color: .cyan.opacity(0.8), radius: 5, x: 0, y: 0)

                // PS5 glyph indicator overlay
                Text("PS5")
                    .font(.system(size: size * 0.32, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .offset(x: size * 0.42, y: size * 0.42)
                    .shadow(color: .blue, radius: 2)
            }

            Text("Madeira")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                        startPoint: UnitPoint(x: phase - 1, y: 0),
                        endPoint: UnitPoint(x: phase, y: 1)
                    )
                )
                .shadow(color: .purple.opacity(0.8), radius: 8, x: 0, y: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [.purple.opacity(0.6), .cyan.opacity(0.6), .pink.opacity(0.6)],
                                startPoint: UnitPoint(x: phase - 1, y: 0),
                                endPoint: UnitPoint(x: phase, y: 1)
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
        )
        .onAppear {
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                phase = 2.0
            }
        }
    }
}

/// Revamped controller setup sheet with simple On/Off toggle, live input tester, and virtual gamepad settings
struct ControllerSetupSheet: View {
    @ObservedObject var manager = GameControllerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Controller Setup") {
                    Toggle("Enable Game Controllers", isOn: $manager.isEnabled)
                        .tint(.green)

                    HStack {
                        Text("Connected Controllers")
                        Spacer()
                        Text("\(manager.connectedControllersCount)")
                            .foregroundColor(.secondary)
                    }

                    if let name = manager.activeControllerName {
                        HStack {
                            Text("Active Device")
                            Spacer()
                            Text(name)
                                .foregroundColor(.primary)
                        }
                    } else {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(manager.isEnabled ? "Scanning / Retrying..." : "Disabled")
                                .foregroundColor(manager.isEnabled ? .orange : .secondary)
                        }
                    }

                    Button("Scan & Retry Detection") {
                        manager.refreshControllers()
                    }
                    .disabled(!manager.isEnabled)
                }

                Section("Virtual Gamepad") {
                    Toggle("Persistent Virtual Gamepad", isOn: $manager.virtualGamepadEnabled)
                        .tint(.blue)
                    Text("Keeps the in-game virtual controller active so reconnected controllers immediately regain control without reopening games.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Live Input Tester (DualSense / Xbox / MFi)") {
                    HStack {
                        Text("Last Action")
                        Spacer()
                        Text(manager.lastPressedButton)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.green)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Left Stick (WASD): \(String(format: "X: %.2f, Y: %.2f", manager.leftStickValues.x, manager.leftStickValues.y))")
                            .font(.caption)
                        Text("Right Stick (Look): \(String(format: "X: %.2f, Y: %.2f", manager.rightStickValues.x, manager.rightStickValues.y))")
                            .font(.caption)
                        Text("Triggers (LT/RT): \(String(format: "LT: %.2f, RT: %.2f", manager.triggerValues.0, manager.triggerValues.1))")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Controller Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Phone & System Optimization, JIT Pool Size, and Wine Desktop Resolution settings sheet
struct PhoneSettingsSheet: View {
    @Binding var selectedRes: String
    @Binding var jitPoolMB: Int
    @Binding var phoneOptimization: Bool
    @Environment(\.dismiss) private var dismiss

    let resOptions = [
        ("Native Screen (Auto / Full)", "native"),
        ("1920 x 1080 (1080p FHD)", "1920x1080"),
        ("1600 x 900 (900p HD+)", "1600x900"),
        ("1280 x 720 (720p HD)", "1280x720"),
        ("1024 x 768 (4:3 Standard)", "1024x768"),
        ("960 x 540 (qHD / Recommended)", "960x540"),
        ("800 x 600 (SVGA Classic)", "800x600")
    ]

    let poolOptions: [(String, Int)] = [
        ("256 MB (Ultra-Light / Safe for 4GB Devices)", 256),
        ("384 MB (Recommended for iPhone XS / 11 / 12)", 384),
        ("512 MB (Balanced)", 512),
        ("640 MB (Medium Games)", 640),
        ("896 MB (Large / Steam CEF Default)", 896),
        ("1024 MB (Maximum - Pro/iPad Devices Only)", 1024)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Device & Memory Optimization"),
                        footer: Text("Optimizes memory and background buffers to avoid iOS Jetsam crash-to-home-screen on phones with 4GB RAM.")) {
                    Toggle("Phone Hardware Optimization", isOn: $phoneOptimization)
                        .tint(.green)
                }

                Section(header: Text("JIT Pool Size"),
                        footer: Text("Size of executable JIT memory allocated for x86-64 code. On iPhone XS (4GB RAM), 256MB or 384MB prevents iOS kernel termination.")) {
                    ForEach(poolOptions, id: \.1) { label, mb in
                        HStack {
                            Text(label)
                                .font(.system(size: 14))
                            Spacer()
                            if jitPoolMB == mb {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            jitPoolMB = mb
                            // Persist to Documents/madeira-pool.txt as well
                            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                try? "\(mb)".write(to: d.appendingPathComponent("madeira-pool.txt"), atomically: true, encoding: .utf8)
                            }
                        }
                    }
                }

                Section(header: Text("Wine Desktop Resolution"),
                        footer: Text("Resolution changes apply to the next Wine desktop launch. Madeira itself can stay open.")) {
                    ForEach(resOptions, id: \.1) { label, value in
                        HStack {
                            Text(label)
                            Spacer()
                            if selectedRes == value {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedRes = value
                        }
                    }
                }
            }
            .navigationTitle("Phone & Display Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var logStore = LogStore.shared
    @StateObject private var gameControllerManager = GameControllerManager.shared
    @State private var jitStatus: JITStatus = .unknown
    @State private var entitlements: EntitlementStatus?
    @State private var debuggerAttached = isDebuggerAttached()
    @ObservedObject private var input = InputSettings.shared
    @State private var pointerPanel = false
    @Namespace private var pointerNS
    @State private var isFileImporterPresented = false
    @State private var isResolutionSheetPresented = false
    @State private var isControllerSheetPresented = false
    @AppStorage("wine_desktop_res") private var selectedResolution: String = "960x540"
    @AppStorage("jit_pool_mb") private var jitPoolMB: Int = 384 // Default to 384MB for phone memory safety
    @AppStorage("phone_optimization") private var phoneOptimization: Bool = true
    /// .compact = iPhone landscape: game surface expands, arrow keys appear.
    @Environment(\.verticalSizeClass) private var vSizeClass

    @State private var showJITAlert = false
    @State private var showBadPoolAlert = false

    enum JITStatus {
        case unknown
        case testing
        case available
        case mappingOnly
        case unavailable
    }

    var body: some View {
        /* ml658: was NavigationView, which is deprecated and — the reason this
         * matters — defaults to a SPLIT VIEW on iPad. TARGETED_DEVICE_FAMILY is
         * "1,2", so iPad is a shipping target, and the whole UI was being forced
         * into a sidebar/detail arrangement it was never laid out for.
         * NavigationStack is single-column on every device. Safe here: there are
         * no NavigationLinks anywhere in the app, so nothing depended on the
         * two-column selection behaviour. */
        NavigationStack {
            Group {
                if vSizeClass == .compact {
                    landscapeBody
                } else {
                    portraitBody
                }
            }
            // Rotation destroys/recreates the UIViewRepresentable across
            // this if/else (two SwiftUI identities) — HARMLESS since
            // 2026-07-05: MetalHostView is a process-lifetime singleton;
            // a fresh placeholder only re-parents the same CAMetalLayer.
            // Animated neon-rainbow title in portrait
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AnimatedNeonRainbowTitle(size: 20)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            isControllerSheetPresented = true
                        } label: {
                            Image(systemName: "gamecontroller")
                                .font(.system(size: 16, weight: .semibold))
                        }

                        Button {
                            isResolutionSheetPresented = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(vSizeClass == .compact)
            .sheet(isPresented: $isControllerSheetPresented) {
                ControllerSetupSheet()
            }
            .sheet(isPresented: $isResolutionSheetPresented) {
                PhoneSettingsSheet(
                    selectedRes: $selectedResolution,
                    jitPoolMB: $jitPoolMB,
                    phoneOptimization: $phoneOptimization
                )
            }
            .alert("JIT Not Enabled", isPresented: $showJITAlert) {
                Button("Enable JIT via StikDebug") {
                    enableJITViaStikDebug()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Wine emulation strictly requires JIT compilation. Please tap 'Enable JIT' or attach a debugger via SideStore / AltStore / StikDebug first.")
            }
            .alert("JIT Memory Pool Placement", isPresented: $showBadPoolAlert) {
                Button("Open Settings") {
                    isResolutionSheetPresented = true
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text("Unable to allocate the requested JIT memory pool at the selected size. Try selecting 256MB or 384MB in Phone Settings (⚙️).")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MadeiraBadPoolNotification"))) { _ in
                showBadPoolAlert = true
            }
            .onAppear {
                jit_install_trap_handler()
                entitlements = EntitlementStatus.check()
                logEntitlementStatus()
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleImportedFile(result)
            }
        }
    }

    /// Portrait: classic tooling layout — header, badges, 240pt game strip,
    /// key row, action buttons, log console.
    private var portraitBody: some View {
        VStack(spacing: 0) {
            // Readouts sit ABOVE the game strip, closest to the surface they
            // describe: entitlement indicators, then the present/FPS readout,
            // then the surface itself. (Only the KEY row stays below — it is
            // input, not instrumentation.)
            //
            // NOTE: the surface is a raw window-level view positioned over the
            // placeholder (MetalHostView.shared), so SwiftUI content laid "on
            // top" of the strip is covered — these rows must be siblings above
            // it, never overlays on it.
            if let ents = entitlements {
                entitlementBadges(ents)
            }
            HStack(spacing: 6) {
                FPSOverlay()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            MadeiraMetalView()
                .frame(height: 240)
                .background(Color.black)
                .onAppear { TouchControlsHost.attach() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()   // re-frame to the new bounds
                }
            HStack(spacing: 6) {
                if pointerPanel {
                    // The cursor button has slid to the leftmost slot and become
                    // the close control; matchedGeometryEffect animates the slide.
                    pointerToggleButton
                    pointerModeToggle
                    pointerSensSlider
                } else {
                    Group {
                        keyButton("⏎", vk: 0x0D)   // VK_RETURN
                        keyButton("␣", vk: 0x20)   // VK_SPACE
                        keyButton("Esc", vk: 0x1B) // VK_ESCAPE
                        Button { MetalBackedView.toggleKeyboard() } label: {
                            Text("⌨").font(.system(size: 20))
                                .frame(minWidth: 40, minHeight: 32)
                                .background(Color.secondary.opacity(0.25))
                                .cornerRadius(6)
                        }
                        JoystickKeyView()
                    }
                    .transition(.opacity)
                    pointerToggleButton
                    diagToggleButton
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // The expanded pad overflows this row; without a raised zIndex the
            // later VStack siblings (action buttons, log) would draw over it.
            .zIndex(10)
            Divider()
            actionButtons
            Divider()
            logConsole
        }
    }

    /// Landscape: game mode. Full-height 4:3 surface centered (aspect-fit
    /// happens in MetalBackedView); ALL controls live in the pillarbox
    /// bars left/right of the game — the window-level surface would cover
    /// anything drawn over the game area itself. No header/log/nav chrome.
    private var landscapeBody: some View {
        GeometryReader { geo in
            let gameW = min(geo.size.width, geo.size.height * 4.0 / 3.0)
            let barW = max((geo.size.width - gameW) / 2.0, 44)
            ZStack {
                Color.black
                MadeiraMetalView()
                // Animated neon-rainbow title and FPS readout in landscape pillarbox bars
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        AnimatedNeonRainbowTitle(size: 13)
                            .padding(.leading, 8)
                            .padding(.top, 8)
                        Spacer()
                    }
                    .frame(width: barW, alignment: .leading)
                    Spacer(minLength: 0)
                    VStack {
                        FPSOverlay(compact: true)
                        Spacer()
                    }
                    .frame(width: barW)
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    /// Hold-to-press key: VK down on touch, VK up on release — for keys
    /// games treat as held (arrows). Same winios queue as keyButton.
    private func holdKeyButton(_ label: String, vk: Int32, big: Bool = false) -> some View {
        HoldKeyView(label: label, vk: vk, big: big)
    }

    /// Small on-screen key: posts VK down, then up 60ms later, through the
    /// winios input queue (same path as touch→mouse).
    // ml641 pointer panel ------------------------------------------------
    private var pointerToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { pointerPanel.toggle() }
            // The window-level pad fades itself; see JoystickPadState.hidden.
            JoystickPadState.shared.hidden = pointerPanel
        } label: {
            Image(systemName: pointerPanel ? "xmark" : "cursorarrow")
                .font(.system(size: 17, weight: .medium))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .matchedGeometryEffect(id: "pointerBtn", in: pointerNS)
    }

    /// ml649: heavy diagnostics on/off, live. Stroke icon, dimmed when quiet —
    /// same visual language as the controls-visibility button.
    private var diagToggleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.diagnostics.toggle()
        } label: {
            Image(systemName: "ladybug")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(input.diagnostics ? 1.0 : 0.35))
                .frame(minWidth: 40, minHeight: 32)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var pointerModeToggle: some View {
        Button {
            input.relative.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(input.relative ? "Relative" : "Absolute")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 82, minHeight: 32)
                .background((input.relative ? Color.accentColor : Color.secondary).opacity(0.28))
                .cornerRadius(6)
        }
        .transition(.opacity)
    }

    /// One slider bound to whichever mode is live, so the two values are edited
    /// independently and both persist.
    private var pointerSensSlider: some View {
        HStack(spacing: 8) {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.10...8.0)
            Text(String(format: "%.2f", input.relative ? input.sensRel : input.sensAbs))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func keyButton(_ label: String, vk: Int32) -> some View {
        Button(action: {
            winios_post_key(vk, 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) {
                winios_post_key(vk, 0)
            }
        }) {
            Text(label)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(minWidth: 34, minHeight: 30)
                .background(Color.white.opacity(0.15))
                .cornerRadius(6)
        }
    }

    private func entitlementBadges(_ ents: EntitlementStatus) -> some View {
        HStack(spacing: 8) {
            // Live debugger/JIT state, not the (macOS-only, never granted on
            // iOS) allow-jit entitlement the old badge checked.
            entitlementBadge("JIT", granted: debuggerAttached)
            entitlementBadge("Memory+", granted: ents.increasedMemory)
            entitlementBadge("64-bit VA", granted: ents.extendedVA)
            if gameControllerManager.connectedControllersCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundColor(.green)
                    Text(gameControllerManager.activeControllerName ?? "Controller")
                        .font(.caption2)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            debuggerAttached = isDebuggerAttached()
        }
    }

    private func entitlementBadge(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .foregroundColor(granted ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(granted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }

    private func logEntitlementStatus() {
        guard let ents = entitlements else { return }
        logStore.log("Checking entitlements...")
        logStore.log("  allow-jit: \(ents.jitAllowed)", level: ents.jitAllowed ? .success : .error)
        logStore.log("  increased-memory-limit: \(ents.increasedMemory)", level: ents.increasedMemory ? .success : .debug)
        logStore.log("  extended-virtual-addressing: \(ents.extendedVA)", level: ents.extendedVA ? .success : .debug)
        if !ents.extendedVA {
            logStore.log("  Tip: Use GetMoreRam to inject extended-virtual-addressing", level: .info)
        }
    }

    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button("Enable JIT") {
                    enableJITViaStikDebug()
                }
                .buttonStyle(.borderedProminent)

                Button("Steam Testing") {
                    guard jit_check_debugged() else {
                        logStore.log("Steam Testing requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    let deskW = 1024, deskH = 768
                    guard prepareSteamLaunch() else { return }
                    unsetenv("MADEIRA_SOCK_WIRE")
                    unsetenv("FEX_O0")
                    unsetenv("MADEIRA_NO_DFE")
                    unsetenv("MADEIRA_IR_TOPO")
                    setenv("MADEIRA_IRCAP_RVA", "0x4db25b", 1)
                    setenv("MADEIRA_IRCAP_MODULE", "mono-2.0-bdwgc.dll", 1)
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) cmd /c C:\\steam-launch.bat", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    unsetenv("MADEIRA_DUMP_SURFACES")
                    setenv("MADEIRA_SURF_SEQ", "10", 1)
                    setenv("MADEIRA_DEAD_RELEASE", "0", 1)
                    setenv("MADEIRA_SRCWATCH", "off", 1)
                    setenv("MADEIRA_SRCWATCH_ROWS", "0,400", 1)
                    setenv("MADEIRA_JITLESS", "1", 1)
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Wine Virtual Desktop") {
                    guard jit_check_debugged() else {
                        logStore.log("Wine Virtual Desktop requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    var deskW = 960
                    var deskH = 540
                    if selectedResolution == "native" {
                        let b = UIScreen.main.nativeBounds
                        deskW = Int(max(b.width, b.height))
                        deskH = Int(min(b.width, b.height))
                    } else {
                        let parts = selectedResolution.split(separator: "x")
                        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                            deskW = w
                            deskH = h
                        }
                    }
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) C:\\windows\\system32\\services.exe", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                Button("Install / Run EXE") {
                    guard jit_check_debugged() else {
                        logStore.log("Running Windows executables requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    isFileImporterPresented = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button("Stray (UE4, -dx11)") {
                    guard jit_check_debugged() else {
                        logStore.log("Stray requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Stray\\Hk_project\\Binaries\\Win64\\Stray-Win64-Shipping.exe", 1)
                    var args = "Hk_project -dx11 -windowed"
                    if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                       let txt = try? String(contentsOf: d.appendingPathComponent("madeira-args.txt"), encoding: .utf8) {
                        let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { args = v }
                    }
                    setenv("MADEIRA_ARGS", args, 1)
                    unsetenv("MADEIRA_DESKTOP")
                    logStore.log("Stray: args = \(args)")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Thumper (standalone)") {
                    guard jit_check_debugged() else {
                        logStore.log("Thumper requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    setenv("MADEIRA_EXE",
                           "C:\\Program Files\\Thumper\\THUMPER_win10.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button("x64 DX11 cube") {
                    guard jit_check_debugged() else {
                        logStore.log("x64 DX11 cube requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    setenv("MADEIRA_EXE", "cube-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button("x64 clock test") {
                    guard jit_check_debugged() else {
                        logStore.log("Clock test requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    setenv("MADEIRA_EXE", "clocktest-x64.exe", 1)
                    unsetenv("MADEIRA_ARGS")
                    unsetenv("MADEIRA_DESKTOP")
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)

                Button("arm64 DX11 cube") {
                    guard jit_check_debugged() else {
                        logStore.log("arm64 DX11 cube requires JIT. Tap 'Enable JIT' first.", level: .error)
                        showJITAlert = true
                        return
                    }
                    runTriangleTest()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button("Clear Log") {
                    logStore.clear()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
    }

    private func runTriangleTest() {
        logStore.log("D3D11 triangle test: full sequence", level: .info)
        // Reuse the existing full Wine sequence but target triangle.exe.
        // WineProcessBridge has the program baked in for now — to flip it
        // requires a signature change. For this iteration we rely on the
        // build's WineProcessBridge.m pointing at triangle.exe.
        runWineFullSequence()
    }

    private var logConsole: some View {
        let entries = logStore.entries.sorted(by: { $0.lastTimestamp > $1.lastTimestamp })
        return List(entries) { entry in
            HStack(alignment: .top, spacing: 8) {
                // Timestamp of LAST occurrence
                Text(timeString(entry.lastTimestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                // Level chip
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(colorForLevel(entry.level))
                    .frame(width: 28, alignment: .leading)
                // Last raw message (the most recent line that matched this signature)
                Text(entry.lastRaw)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                // Count badge (only if count > 1)
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
    }

    // ml540: ONE formatter for the whole app, built once on first use.
    //
    // This used to construct a fresh DateFormatter on every call — once per log
    // row per body evaluation — and each new instance opens ICU underneath
    // (udat_open -> SimpleDateFormat::initialize). That is not just wasteful,
    // it is where ml539 died: after Wine's main thread exited, ICU ran
    // _platform_strcmp on a pointer into that dead thread's stack (x0 sat 0x68C
    // below its recorded tsd_base) and took the whole app down. A single
    // long-lived formatter does the ICU open ONCE, at first log render, long
    // before Wine exists.
    private static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Main-thread only (SwiftUI body evaluation) — DateFormatter is not safe to
    // share across threads.
    private func timeString(_ date: Date) -> String {
        ContentView.hhmmss.string(from: date)
    }

    private var statusColor: Color {
        switch jitStatus {
        case .unknown: return .gray
        case .testing: return .yellow
        case .available: return .green
        case .mappingOnly: return .orange
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch jitStatus {
        case .unknown: return "Not tested"
        case .testing: return "Testing..."
        case .available: return "Available"
        case .mappingOnly: return "Needs debugger"
        case .unavailable: return "Unavailable"
        }
    }

    private var deviceInfo: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func colorForLevel(_ level: LogStore.LogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .debug: return .gray
        }
    }

    private func runJITTest() {
        jitStatus = .testing
        logStore.log("Starting JIT test...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT for this app.", level: .error)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let mappingOk = jit_test_mapping()
                        DispatchQueue.main.async {
                            if mappingOk {
                                jitStatus = .mappingOnly
                                logStore.log("Dual mapping works. Enable JIT via StikDebug to unlock execution.", level: .success)
                            }
                        }
                    }
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop detected — try 'Test JIT (Alt)' for debugger-allocated memory", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("JIT test failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runJITTestStrategy2() {
        jitStatus = .testing
        logStore.log("Starting JIT test (Strategy 2: debugger-allocated RX)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute_strategy2()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional (strategy 2)!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT.", level: .error)
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop — debugger-allocated pages also rejected", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("Strategy 2 failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runFEXTest() {
        logStore.log("Starting FEX-Emu integration test...")
        jitStatus = .testing

        // Set up FEX log callback
        fex_set_log_callback { msg in
            if let msg = msg {
                let str = String(cString: msg)
                DispatchQueue.main.async {
                    LogStore.shared.log(str, level: .debug)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = fex_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("FEX-Emu test PASSED: x86-64 code returned 42!", level: .success)
                case -1:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test FAILED (init/setup error)", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test returned \(result)", level: .error)
                }
            }
        }
    }

    private func enableJITViaStikDebug() {
        jitStatus = .testing
        logStore.log("Requesting JIT via StikDebug URL scheme...")

        StikJITHelper.enableJIT { success in
            if success {
                jitStatus = .available
                logStore.log("JIT enabled! Debugger attached.", level: .success)
            } else {
                jitStatus = .unavailable
                logStore.log("Failed to enable JIT via StikDebug", level: .error)
            }
        }
    }

    /// Full sequence: allocate JIT pool, start wineserver, start Wine.
    /// Debugger stays attached during PE loading so mprotect_exec can use BRK
    /// to prepare code pages. Detach happens after Wine finishes + recovery.
    private func runWineFullSequence() {
        guard jit_check_debugged() else {
            logStore.log("JIT not enabled. Press 'Enable JIT' first.", level: .error)
            DispatchQueue.main.async {
                self.showJITAlert = true
            }
            return
        }

        logStore.log("Running full Wine sequence...")

        // Start a main thread heartbeat to diagnose hang
        var heartbeatCount = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            heartbeatCount += 1
            os_log("[HEARTBEAT] main thread alive #%d", heartbeatCount)
        }

        // Pause UI flushing — prevents ALL SwiftUI re-renders during Wine execution,
        // so zero main thread hang time accumulates while debugger is attached
        logStore.uiPaused = true

        // Suppress os_log from wineserver — hundreds of messages/sec cause os_log buffer
        // contention that blocks the main thread RunLoop, triggering iOS hang detection
        ws_log_quiet = 1

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Allocate JIT pool (BRK suspends entire process)
            // 128 MB was enough for cube but Thumper exhausts it (more PE
            // copies + larger FEX block cache). Desktop mode holds the
            // session's aarch64 image set AND every child's x64 set AND the
            // FEX code buffers in ONE pool: Thumper-under-desktop hit 199MB
            // of image copies alone (2026-07-06), leaving the FEX tail carve
            // colliding with the head. 384 MB fits both plus slack; the pool
            // is dual-map + NO_FOOTPRINT so unwritten pages cost nothing.
            //
            // 2026-07-10 (Steam S3): 384 MB is VIRTUAL-exhausted by Steam's
            // pseudo-process fan-out — steam.exe + services + rpcss + cmd +
            // conhost + steamerrorreporter64 each copy their whole DLL set
            // (owner-keyed, no .text sharing yet) → 138 image copies hit
            // ~365 MB and the crash reporter's ntdll can't fit → the load
            // fails and execution BUS-faults on the un-committed image. Since
            // the pool is jetsam-exempt + demand-committed (unwritten pages
            // cost nothing), raising the VIRTUAL cap is a cheap, safe unblock.
            // 640 MB clears the current fan-out with headroom to reach the
            // ole32 delay-load (FEX riprel probe) and beyond. The real fix for
            // the PHYSICAL duplication is .text sharing (deferred project).
            //
            // 2026-07-10 pm (task #34 / CEF): 896 MB — libcef.dll's 212MB
            // pool copy EXHAUSTED 640 (bump 412MB + no contiguous 212MB →
            // libcef load degraded → init CHECK). Pure-x64 skip-copy was
            // trialed and reverted (broke x18-trampoline layout, ml68);
            // until skip-copy or .text sharing lands, buy headroom. Virtual
            // is jetsam-exempt; the copy itself is ~212MB real RSS when
            // written.
            // 2026-08-01 (ml364): 1152 MB — ml363 died at MSM depth on pool
            // EXHAUSTION (bump 858MB, freelist 0, tail-reserve 64MB) when
            // Chrome's in-proc GPU thread requested a doubled 32MB EC code
            // buffer; the fallback landed non-executable in the guest band and
            // FEX scribbled through a garbage CodeBuffer. NOTE the jetsam
            // ledger note above is STALE: the pool was never exempt and
            // arrives FULLY DIRTY from StikDebug's TXM blessing writes, so
            // this +256MB costs +256MB of the 4096MB budget up front. The
            // ml362/ml363 footprint work (peak 3804→3190) is what pays for
            // it. The real fix for both sides is still .text sharing.
            // 2026-08-01 (ml367): back to 896 MB. ml364 needed 1152 because the
            // shipped PE DLLs carried DWARF debug sections (llvm-mingw links
            // -Wl,-debug:dwarf) and the pool copies the ENTIRE image, so 42% of
            // every copy was debug info with no runtime purpose. Stripping them
            // (llvm-strip --strip-debug over the bundle) drops projected peak
            // pool use 894 -> ~653 MB, so 896 restores the ml364-equivalent
            // headroom (~243 MB) while returning 256 MB of footprint — the pool
            // is dirty from birth, so its SIZE is what costs, not its usage.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-02 (ml421): 1024 MB. ml420 (post-#69-fix, deepest run yet:
            // cycle 41) refilled the stripped 896 pool anyway — head 768MB of
            // copies + 176MB tail of EC code buffers collided; the doubled 32MB
            // GPU-thread buffer was refused and the ml361/ml363 ClearCache
            // wild-write returned (now also honestly REFUSED unix-side,
            // rev=ml421). +128MB is the depth lever that fits under jetsam:
            // ml420 peaked 3837 phys; 3837+128=3965 < 4096. Tight — if jetsam
            // returns, the durable fix is .text sharing, not more pool.
            // 2026-08-02 (ml423): BACK to 896. Jetsam DID return — ml422 died a
            // silent EXC_RESOURCE kill at 2.5min (peak 3904, log stops mid-line),
            // exactly the predicted cost of the +128MB dirty-at-birth pool.
            // ml421's honest EC_CODE refusal makes pool exhaustion GRACEFUL now
            // (ctor halving, worst case one thread's 0xdead fault) while jetsam
            // kills the whole app — 896 + graceful degradation strictly beats
            // 1024 + jetsam roulette. Durable fix remains .text sharing.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-03 (ml458): STAY at 896 — growth is closed for good.
            // jetsam killed 1024 twice (ml422 peak 3904) and the no-footprint
            // exemption is unreachable: all four (entry-flags, owner) variants
            // return kr=4, and the plain ones expose why — the named entry
            // covers 16KB of the 896MB object, i.e. the kernel wants an entry
            // naming the WHOLE object, which we can never build over memory
            // whose object StikDebug created. Pool stays dirty-from-birth and
            // jetsam-counted, so SIZE is the cost and 896 is the ceiling.
            // ⛔ ml457 re-trialed pure-x64 skip-copy (already dead per ml68
            // above) and it failed again for a different reason: x64 guest
            // RIPs ARE pool-copy aliases, so the copy is the execution
            // substrate — steam.exe died in seconds. Do not try a third time.
            // The remaining levers are USE-side: the 276MB of duplicate copies
            // (.text sharing) and the 214MB tail of EC code buffers.
            // ml668: RUNTIME-SELECTABLE. 896 stays the default and the only
            // value proven for Steam/CEF. 384 is the direct-game experiment:
            // the last good Book of the Dead run used ~139MB of head + ~48MB
            // of tail, so 384 leaves ~197MB of observed slack while returning
            // ~512MB of footprint -- and the pool is dirty from birth, so its
            // SIZE is the cost, not its usage. The VA floor is no longer a
            // hand-paired constant (ml668 derives it from the pool actually
            // allocated), so changing this is now a one-line change.
            // Override lives in Documents/madeira-pool.txt (a bare number of MB)
            // so it can be swapped between runs without a rebuild, and deleting
            // the file reverts to the proven default. Clamped to sane values --
            // a typo here would otherwise move the VA floor with it.
            // JIT Pool Size is controlled via Phone Settings (default 384MB for phone stability)
            var poolSizeMB = jitPoolMB
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-pool.txt"), encoding: .utf8),
               let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               mb >= 256, mb <= 1152 {
                poolSizeMB = mb
            }
            logStore.log("Using JIT pool size: \(poolSizeMB)MB (Phone Optimization: \(phoneOptimization ? "ON" : "OFF"))", level: .info)

            // Phone Hardware Optimization: Clamp extra buffers on phones to keep total footprint low
            if phoneOptimization {
                setenv("MADEIRA_PHONE_OPT", "1", 1)
                // Limit surface queue bursts to prevent spikes in physical memory
                setenv("MADEIRA_SURF_SEQ", "4", 1)
            }
            // ml694: W^X A/B switch. Documents/madeira-wx.txt containing "0"
            // disables page demotion for the SAME binary, so the on/off
            // comparison needs one rebuild, not two. The previous gate read
            // container paths that can never exist, so it silently forced
            // ENABLED and no A/B was actually possible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wx.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_WX", v, 1)
                logStore.log("W^X override: MADEIRA_WX=\(v) via madeira-wx.txt")
            }

            // ml727: wine-mono backpatcher bridge A/B. Documents/madeira-mono-bridge.txt
            // == "1" sets MADEIRA_WINEMONO_BRIDGE, which arms FEX's Mono code-patching
            // optimisation for wine-mono (recognised since ml712 but activation left
            // opt-in because the bridge reclassifies an XCHG from a true atomic exchange
            // into an alias-directed plain write).
            //
            // Worth arming here: the dominant fault site emits SWPAL, which is exactly
            // what FEX generates for a guest XCHG, and the patching XCHGs sit inside
            // libmono -- so the bridge's "RIP must lie inside Mono" test should pass.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-bridge.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_WINEMONO_BRIDGE", v, 1)
                    logStore.log("Mono bridge: MADEIRA_WINEMONO_BRIDGE=\(v) via madeira-mono-bridge.txt")
                }
            }

            // ml716: syscall-frame context A/B. Documents/madeira-ctx-frame.txt == "1"
            // makes ios_fill_thread_context() report a thread parked inside a syscall
            // using its saved Wine syscall frame (TEB+0x378) instead of the Mach-O
            // registers it happens to be executing. Off by default; native code reads
            // only the environment variable.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-ctx-frame.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_CTX_FRAME", v, 1)
                    logStore.log("Context source: MADEIRA_CTX_FRAME=\(v) via madeira-ctx-frame.txt")
                }
            }

            // ml744: DXMT options passthrough. Documents/madeira-dxmt.txt is copied
            // verbatim into DXMT_CONFIG, which the renderer's config parser reads as
            // inline "key=value" lines, so options can be tried without a rebuild.
            // d3d11.mipClampBC=N is the one that matters for memory: this GPU cannot
            // sample BC, so those textures are expanded to uncompressed and cost 2-8x
            // their shipped size.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-dxmt.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("DXMT_CONFIG", v, 1)
                    logStore.log("DXMT config: \(v) via madeira-dxmt.txt")
                }
            }

            // ml734: Theorafile call tracer. Documents/madeira-tf-trace.txt == "1"
            // redirects libtheorafile's tf_* exports through wrappers in
            // tftrace-x64.dll that call the original and report the RETURN
            // value. The intro decodes and plays, the stream reaches a clean
            // end of file, the decoder stops reading -- and the game never
            // leaves VideoContext. File EOF is not decoder EOS, and a call
            // count cannot tell "tf_eos returns false forever" from "it returns
            // true and the managed side ignores it". Only the return value can.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-tf-trace.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_TF_TRACE", v, 1)
                    logStore.log("Theorafile tracer: MADEIRA_TF_TRACE=\(v) via madeira-tf-trace.txt")
                }
            }

            // ml731: Windows shared-data clock A/B. Documents/madeira-usd-time.txt == "1"
            // makes wineserver update KUSER_SHARED_DATA's SystemTime, InterruptTime
            // and TickCount again. Without it those stay frozen at their init values,
            // so GetTickCount/Environment.TickCount/DateTime.UtcNow never advance and
            // every time-gated transition in a managed game waits forever while the
            // renderer keeps drawing. Opt-in only because the old code claimed the
            // write faulted; this should become unconditional once proven.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-usd-time.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_USD_TIME", v, 1)
                    logStore.log("Shared-data clock: MADEIRA_USD_TIME=\(v) via madeira-usd-time.txt")
                }
            }

            // ml730: REAL thread suspension A/B. Documents/madeira-real-suspend.txt == "1"
            // makes a Wine suspend actually stop the Mach thread and keep it stopped
            // until the matching resume, instead of only snapshotting its registers
            // and bumping a counter while the target keeps running.
            //
            // Off by default and reversible on purpose: wineserver is a thread inside
            // this same Mach process and shares the allocator with the guest, so truly
            // freezing a thread that holds the malloc lock or FEX's CodeInvalidationMutex
            // can deadlock whoever suspended it. Windows apps tolerate preemptive suspend
            // because the suspender does not share their heap; here it does.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-real-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_REAL_SUSPEND", v, 1)
                    logStore.log("Thread suspension: MADEIRA_REAL_SUSPEND=\(v) via madeira-real-suspend.txt")
                }
            }

            // ml713: Mono suspend-policy A/B. Documents/madeira-mono-suspend.txt
            // containing "preemptive" (or "coop"/"hybrid") sets MONO_THREADS_SUSPEND
            // for wine-mono, so the comparison needs no rebuild.
            //
            // EXPERIMENT, NOT A FIX, and deliberately not a default. Marvel Cosmic
            // Invasion deadlocks with one thread owning a Mono critical section while
            // looping on mono_lls_find/usleep waiting for a thread-info record, and six
            // threads queued behind that section. Preemptive suspend would sidestep the
            // handshake -- but it needs SuspendThread + GetThreadContext to yield a
            // coherent x86-64 context for a guest thread stopped anywhere, including
            // mid-JIT-block, and that path has never been exercised under FEX. It may
            // trade a deadlock for a worse failure. If it does get in-game, that is NOT
            // evidence for any particular theory of the deadlock.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MONO_THREADS_SUSPEND", v, 1)
                    logStore.log("Mono suspend policy: MONO_THREADS_SUSPEND=\(v) via madeira-mono-suspend.txt")
                }
            }

            winios_phase("pool-alloc-begin")
            logStore.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
            let t0 = CFAbsoluteTimeGetCurrent()
            let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            winios_phase("pool-ready")
            logStore.log("BRK suspension lasted \(String(format: "%.2f", elapsed))s")

            // ml762: remote Metal backend. Documents/madeira-remote.txt holds
            // "<host-ip> <token>" and routes winemetal to a Metal daemon on that
            // host instead of the local device. The mode is decided ONCE per
            // process: flipping it later would leave handles from two address
            // spaces alive at the same time, which is precisely what the handle
            // tag exists to make impossible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-remote.txt"), encoding: .utf8) {
                let parts = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    setenv("DXMT_REMOTE_METAL", parts[0], 1)
                    setenv("RMETAL_TOKEN", parts[1], 1)
                    logStore.log("remote Metal: host=\(parts[0]) via madeira-remote.txt", level: .success)
                } else if !parts.isEmpty {
                    logStore.log("madeira-remote.txt needs '<host-ip> <token>'", level: .error)
                }
            }

            // ml761: top-level API census. Documents/madeira-apicensus.txt == "1"
            // counts every call across the PE->unix winemetal boundary and
            // classifies each as producer, consumer, lifetime, query, sync,
            // presentation or bulk-memory. Needed because a packed command
            // batch carries GUEST handles -- raw pointer casts, meaningless on
            // another machine -- so every handle producer and consumer has to
            // be redirected together.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-apicensus.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_API_CENSUS", v, 1)
                logStore.log("API census: DXMT_API_CENSUS=\(v) via madeira-apicensus.txt")
            }

            // ml760: shadow-pack mode. Documents/madeira-shadow.txt == "1" packs
            // and validates every real render batch into the remote wire format,
            // then discards it and renders locally as normal. Exercises the
            // packer against live traffic where being wrong costs nothing. The
            // check that matters is packed counts equalling census counts: a
            // silently skipped command would otherwise surface as a subtly wrong
            // frame on another machine.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-shadow.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_SHADOW_PACK", v, 1)
                logStore.log("shadow pack: DXMT_SHADOW_PACK=\(v) via madeira-shadow.txt")
            }

            // ml758: wmtcmd census. Documents/madeira-census.txt == "1" counts
            // which of the 59 render/compute/blit command types a workload
            // actually emits, and how large their sidecar data gets. Needed
            // before serialising wmtcmd_* for the remote Metal transport --
            // building a schema for all 59 on speculation would be weeks of
            // work for commands no title may ever issue.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-census.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_CMD_CENSUS", v, 1)
                logStore.log("wmtcmd census: DXMT_CMD_CENSUS=\(v) via madeira-census.txt")
            }

            // ml757: FEX arena placeholder. Documents/madeira-arena.txt == "1"
            // makes Wine reserve FEX's host arena before any PE loads. OFF by
            // default: FEX still selects its own band, and on hardware that
            // band IS the reservation, so enabling it starves FEX and kills
            // x64 before the first window. Proven correct on the research VM
            // (8GB held, 0 of 123 guest images inside it) -- turn on only once
            // FEX consumes WINE_IOS_FEX_ARENA_BASE/SIZE instead of choosing.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-arena.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_FEX_ARENA", v, 1)
                logStore.log("FEX arena placeholder: MADEIRA_FEX_ARENA=\(v) via madeira-arena.txt")
            }

            // ml748: W^X A/B probe. Documents/madeira-wxprobe.txt == "1" runs it.
            // Loading xtajit64.dll faults writing its .rdata on the jailbroken
            // research VM and not on this phone, with CS_DEBUGGED live in both,
            // so attachment is not the variable. Either the VM is stricter than
            // real hardware (its patchVmMapProtect() was removed, and that is
            // what forces W to stick on file-backed pages), or hardware masks a
            // genuine bug and the loader must stop holding RWX over image pages.
            // Reasoning cannot separate those; the SAME build reporting on both
            // machines can. Runs here because it needs the real container, the
            // real sandbox and a live cs_wx_enabled map -- a standalone binary
            // over SSH already answered this wrongly once.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wxprobe.txt"), encoding: .utf8),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                logStore.log("W^X probe armed via madeira-wxprobe.txt", level: .success)
                jit_wx_probe()
            }

            if let pool = pool {
                logStore.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
                setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
                setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
                setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            } else {
                logStore.log("JIT pool allocation FAILED — not starting Wine.", level: .error)
                logStore.log("  Try adjusting JIT Pool Size in Settings (e.g. 256MB or 384MB).", level: .info)
                DispatchQueue.main.async {
                    self.logStore.uiPaused = false
                    NotificationCenter.default.post(name: NSNotification.Name("MadeiraBadPoolNotification"), object: nil)
                }
                return
            }

            // Step 1b (ml524, #67): DETACH THE DEBUGGER NOW, while the VM map is small.
            //
            // Every ~54s whole-app stall coincides with StikDebug DEPARTING — clean
            // exit(0) and jetsam-kill alike (12:07:43 exit(0) -> GAP 54.0s at 12:07:49;
            // 12:13:58 cpulimit kill -> GAP 53.8s starting 64ms BEFORE the kill log).
            // Departure is the trigger; the manner of death is irrelevant. StikDebug
            // burns its 48s-CPU-per-60s budget in ~52s every single run, so an
            // UNCONTROLLED departure mid-game is guaranteed. Detaching here pays the
            // cost ONCE, at a moment we choose, before anything is on screen.
            //
            // Why it may also be CHEAPER here: on attach the kernel unnests the DYLD
            // shared region in OUR map ("increases system memory footprint until the
            // target exits"), so teardown plausibly scales with VM-map complexity —
            // and right now the map is a fraction of what it becomes under Steam
            // (91 threads / 2512MB). The [early-detach] timing below tests exactly that.
            //
            // Safe NOW and not before: ml522/ml523 made US the task-level Mach handler
            // for bad-access + bad-instruction + breakpoint, so the fault backstop that
            // used to require a live debugger (madeira-jit.js: "NEVER detach here ... every
            // later escalated fault parks its thread forever", the ml345 wedge) is ours.
            // And all executable memory already comes from the pool granted above —
            // virtual_ios.c copies every PE .text into it rather than mprotecting,
            // because iOS/TXM blocks mprotect(PROT_EXEC) outright.
            //
            // ORDERING MATTERS: our task-port claim installs at wine's first thread
            // setup, which is AFTER this point, so this BRK still reaches StikDebug.
            // Flip to false to A/B against the old attached-for-the-whole-run behaviour.
            let earlyDetach = true
            if earlyDetach, pool != nil {
                let dt0 = CFAbsoluteTimeGetCurrent()
                StikJITHelper.detachDebugger()
                let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
                logStore.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms),
                             level: dms > 5000 ? .error : .success)
            } else if !earlyDetach {
                logStore.log("[early-detach] rev=ml524 DISABLED — debugger stays attached all run")
            }

            winios_phase("detach-done")

            // Step 2: Start wineserver
            self.startWineserver()
            winios_phase("wineserver-up")

            // Step 3: Start Wine (debugger still attached for PE loading BRK calls)
            Thread.sleep(forTimeInterval: 2.0)
            winios_phase("wine-start")
            self.startWineProcess()

            // Step 4: Wait for Wine to finish instead of fixed timer
            // Poll wine_process_is_running() — it clears when __wine_main returns
            // For real games this never returns (message loop runs forever), so
            // the cap is what matters. After detach, the dual-mapped JIT pool
            // keeps existing blocks executable; only NEW BRK-based compiles
            // fail.
            //
            // 2026-05-13 first-frame: Thumper splash renders at ~50s but JIT is
            // STILL compiling new FMOD blocks 3M log lines later — audio init
            // is huge (~14k unique RIPs in fmod64.dll alone). Bumped to 300s
            // to let FMOD finish init before debugger detach; otherwise main
            // game loop never engages because Present is gated on audio ready.
            logStore.log("Waiting for Wine to finish PE loading...")
            // 2026-07-03 early detach: attached-mode runs the whole guest
            // ~2x slower (measured 1.2s → 0.74s per present at detach) and
            // on iOS 27 presented frames only reliably reach glass after
            // detach. Post-detach is safe now: trap-mode JIT writes go via
            // the Mach emulator (no debugger), pool pages are pre-executable
            // (dual map), page0 runs once on the first thread, and a
            // post-detach compile was observed working (real_compiles
            // 7093→7094, no faults). So: detach once the game is actually
            // presenting (present #2 = first post-splash frame) plus a
            // settle window, instead of waiting out the full 1200s cap.
            let maxWait = 1200.0  // hard safety cap (unchanged)
            // 2026-07-03 second iteration: detach on present #1 (splash shown)
            // instead of #2. The 3-minute splash-hold is the game loading —
            // running it detached should roughly halve it. Riskier than #2
            // (thousands of load-time compiles + worker-thread spawns happen
            // post-detach) but all known dependencies are covered: trap-mode
            // writes, pre-executable pool, page0 once-guard.
            let settleAfterFirstPresent = 20.0
            var presentingSince: CFAbsoluteTime? = nil
            let pollStart = CFAbsoluteTimeGetCurrent()
            var lastHeartbeat = CFAbsoluteTimeGetCurrent()
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                // Diagnostic heartbeat: 2026-07-03's detach-at-#1 run never
                // triggered despite presents visibly counting — log what this
                // loop actually observes so that can't happen silently again.
                if now - lastHeartbeat > 30 {
                    lastHeartbeat = now
                    logStore.log("detach-wait: presents=\(madeira_get_present_count()) running=\(wine_process_is_running()) elapsed=\(Int(now - pollStart))s")
                }
                // Task #25: the present heuristic is meaningless in desktop
                // mode — ANY child presenting (cube, a game window) trips it
                // mid-session, and later program launches still need the
                // attached-debugger facilities. Desktop sessions stay
                // attached until the desktop exits (or the safety cap).
                let isDesktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
                if !isDesktopSession {
                    if presentingSince == nil && madeira_get_present_count() >= 1 {
                        presentingSince = now
                        logStore.log("Game is presenting (#1, splash) — early detach in \(Int(settleAfterFirstPresent))s")
                    }
                    if let t = presentingSince, now - t > settleAfterFirstPresent {
                        logStore.log("Early detach: game presenting and settled", level: .success)
                        break
                    }
                }
                if now - pollStart > maxWait {
                    logStore.log("Wine still running after \(Int(maxWait))s, proceeding with detach", level: .error)
                    break
                }
            }
            let wineElapsed = CFAbsoluteTimeGetCurrent() - pollStart
            logStore.log("Wine finished after \(String(format: "%.1f", wineElapsed))s")

            // Step 5: Resume UI + os_log, give main thread time to recover before detach
            DispatchQueue.main.async {
                ws_log_quiet = 0
                logStore.uiPaused = false
            }
            Thread.sleep(forTimeInterval: 2.0)

            // Step 6: Detach debugger — main thread should have zero accumulated hang time
            logStore.log("Detaching debugger...")
            StikJITHelper.detachDebugger()

            DispatchQueue.main.async { heartbeat.invalidate() }
        }
    }

    /// ml589: locate an installed Steam inside the prefix and (re)generate
    /// C:\steam-launch.bat to match. Returns false, having logged the reason,
    /// when there is nothing runnable.
    ///
    /// Generating the batch here fixes a gap that only showed on FRESH prefixes:
    /// steam-launch.bat was never part of prefix-template.tar.gz, it had only
    /// ever been hand-pushed to the dev device, so a new install ran
    /// `cmd /c C:\steam-launch.bat` against a file that did not exist.
    ///
    /// The generated batch launches steam.exe DIRECTLY rather than through
    /// start.exe. That wrapper's teardown is what killed services.exe's RPC
    /// listener in every broken run (ml579/580/584/585) and took the Start menu
    /// with it; launching directly also keeps cmd+conhost alive for the session.
    private func prepareSteamLaunch() -> Bool {
        let fm = FileManager.default
        let prefix = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("wine").path

        // (windows dir, unix dir) — Steam installs to Program Files (x86) by
        // default, but honour a 64-bit-tree install too.
        let candidates = [
            ("C:\\Program Files (x86)\\Steam", "\(prefix)/drive_c/Program Files (x86)/Steam"),
            ("C:\\Program Files\\Steam",       "\(prefix)/drive_c/Program Files/Steam"),
        ]

        var winDirFound: String? = candidates.first(where: {
            fm.fileExists(atPath: "\($0.1)/steam.exe")
        })?.0

        // If steam is not found in prefix, check if a preinstalled steam archive was bundled in the App
        if winDirFound == nil {
            if let bundledSteamTgz = Bundle.main.path(forResource: "steam", ofType: "tar.gz") {
                logStore.log("Found preinstalled Steam bundle in app resources. Extracting...", level: .info)
                let targetSteamDir = "\(prefix)/drive_c/Program Files (x86)/Steam"
                try? fm.createDirectory(atPath: targetSteamDir, withIntermediateDirectories: true)
                let result = bundledSteamTgz.withCString { archivePath in
                    targetSteamDir.withCString { destinationPath in
                        madeira_extract_prefix_tgz(archivePath, destinationPath)
                    }
                }
                if result == 0 {
                    logStore.log("Preinstalled Steam extracted successfully.", level: .success)
                    if fm.fileExists(atPath: "\(targetSteamDir)/steam.exe") {
                        winDirFound = "C:\\Program Files (x86)\\Steam"
                    }
                }
            }
        }

        guard let winDir = winDirFound else {
            logStore.log("Steam is not installed in this prefix.", level: .error)
            logStore.log("  Searched: Program Files (x86)\\Steam and Program Files\\Steam", level: .info)
            logStore.log("  Valve's SteamSetup.exe cannot be used to install it here: the", level: .info)
            logStore.log("  installer AND the Steam.exe it lays down are 32-bit x86, and this", level: .info)
            logStore.log("  build runs x86-64 only (ARM64EC + FEX, no 32-bit emulator).", level: .info)
            logStore.log("  Tip: Tap 'Install / Run EXE' and select a 64-bit Steam .tar.gz archive or folder.", level: .info)
            return false
        }

        let bat = """
        @echo off\r
        rem Generated by Madeira (ml589) — do not hand-edit; rewritten every launch.\r
        start "" "C:\\windows\\system32\\services.exe"\r
        cd /d "\(winDir)"\r
        "\(winDir)\\steam.exe" -no-cef-sandbox -cef-disable-gpu -console -nocrashmonitor -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints\r
        """

        let batPath = "\(prefix)/drive_c/steam-launch.bat"
        do {
            try bat.write(toFile: batPath, atomically: true, encoding: .utf8)
        } catch {
            logStore.log("Could not write steam-launch.bat: \(error.localizedDescription)", level: .error)
            return false
        }
        logStore.log("Steam found at \(winDir)", level: .success)
        return true
    }

    /// Import an installer (.exe) or archive (.zip, .tar.gz) from iOS Files into Wine
    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            logStore.log("Failed to select file: \(error.localizedDescription)", level: .error)
        case .success(let urls):
            guard let selectedURL = urls.first else { return }

            guard selectedURL.startAccessingSecurityScopedResource() else {
                logStore.log("Unable to access selected file permission", level: .error)
                return
            }
            defer { selectedURL.stopAccessingSecurityScopedResource() }

            let fm = FileManager.default
            guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let prefix = docDir.appendingPathComponent("wine").path
            let driveCDir = "\(prefix)/drive_c"
            let installersDir = "\(driveCDir)/Installers"
            let filename = selectedURL.lastPathComponent
            let lowerFilename = filename.lowercased()

            // Robust feature: If user imports a Steam archive (zip / tgz / tar.gz) or game archive,
            // extract it into drive_c automatically!
            if lowerFilename.hasSuffix(".tar.gz") || lowerFilename.hasSuffix(".tgz") {
                logStore.log("Detected tar.gz archive: \(filename). Extracting to drive_c...", level: .info)
                let targetDir: String
                if lowerFilename.contains("steam") {
                    targetDir = "\(driveCDir)/Program Files (x86)/Steam"
                } else {
                    targetDir = driveCDir
                }
                do {
                    try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                    let tempArchive = "\(targetDir)/\(filename)"
                    if fm.fileExists(atPath: tempArchive) { try fm.removeItem(atPath: tempArchive) }
                    try fm.copyItem(at: selectedURL, to: URL(fileURLWithPath: tempArchive))
                    
                    let extractResult = tempArchive.withCString { archivePath in
                        targetDir.withCString { destinationPath in
                            madeira_extract_prefix_tgz(archivePath, destinationPath)
                        }
                    }
                    try? fm.removeItem(atPath: tempArchive)
                    
                    if extractResult == 0 {
                        logStore.log("Successfully extracted \(filename) to \(targetDir)", level: .success)
                    } else {
                        logStore.log("Failed to extract \(filename)", level: .error)
                    }
                } catch {
                    logStore.log("Error extracting archive: \(error.localizedDescription)", level: .error)
                }
                return
            }

            do {
                if !fm.fileExists(atPath: installersDir) {
                    try fm.createDirectory(atPath: installersDir, withIntermediateDirectories: true, attributes: nil)
                }

                // Sanitize filename: replace spaces with underscores so the Wine
                // MADEIRA_ARGS space-tokenizer never splits the path mid-filename.
                let safeFilename = filename.replacingOccurrences(of: " ", with: "_")
                let destPath = "\(installersDir)/\(safeFilename)"
                if fm.fileExists(atPath: destPath) {
                    try fm.removeItem(atPath: destPath)
                }
                try fm.copyItem(at: selectedURL, to: URL(fileURLWithPath: destPath))

                logStore.log("Imported: \(filename) → drive_c\\Installers\\\(safeFilename)", level: .success)

                // Configure Wine to launch the installer/executable inside a virtual desktop window.
                // MADEIRA_EXE = explorer.exe, MADEIRA_ARGS = /desktop=shell,WxH <exe-path>
                // The exe path is space-free thanks to safeFilename above.
                let deskW = 1024, deskH = 768
                setenv("MADEIRA_EXE", "explorer.exe", 1)
                setenv("MADEIRA_ARGS", "/desktop=shell,\(deskW)x\(deskH) C:\\Installers\\\(safeFilename)", 1)
                setenv("MADEIRA_DESKTOP", "1", 1)
                setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                setenv("MADEIRA_SCREEN_H", String(deskH), 1)

                logStore.log("Launching: C:\\Installers\\\(safeFilename) ...", level: .info)
                runWineFullSequence()
            } catch {
                logStore.log("Failed to process imported file: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func startWineserver() {
        logStore.log("Starting wineserver...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        logStore.log("Wine prefix: \(winePrefixPath)")

        let result = wineserver_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wineserver thread launched successfully", level: .success)
        } else {
            logStore.log("Failed to start wineserver (error: \(result))", level: .error)
        }
    }

    private func startWineProcess() {
        logStore.log("Starting Wine process...")

        if wineserver_is_running() == 0 {
            logStore.log("Wineserver not running! Start it first.", level: .error)
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        // Call synchronously — caller already waited for wineserver to be ready
        let result = wine_process_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wine process thread launched", level: .success)
        } else {
            logStore.log("Failed to start Wine process (error: \(result))", level: .error)
        }
    }

    private func testDualMapping() {
        logStore.log("Testing dual-mapped memory properties...")

        DispatchQueue.global(qos: .userInitiated).async {
            testDualMappingImpl()
        }
    }

    private func testDualMappingImpl() {
        logStore.log("Creating 64KB dual-mapped region...")

        guard let region = jit_region_create(65536) else {
            logStore.log("Failed to create dual-mapped region", level: .error)
            return
        }

        let rwPtr = jit_region_rw_ptr(region)
        let rxPtr = jit_region_rx_ptr(region)
        let size = jit_region_size(region)

        logStore.log("Region created: size=\(size)")
        logStore.log("  RW ptr: \(String(format: "%p", Int(bitPattern: rwPtr)))")
        logStore.log("  RX ptr: \(String(format: "%p", Int(bitPattern: rxPtr)))")

        // Test 1: Write to RW, verify readable from RX
        let testPattern: UInt32 = 0xDEADBEEF
        rwPtr?.assumingMemoryBound(to: UInt32.self).pointee = testPattern
        let readBack = rxPtr?.assumingMemoryBound(to: UInt32.self).pointee

        if readBack == testPattern {
            logStore.log("Dual mapping verified: write to RW visible from RX", level: .success)
        } else {
            logStore.log("Dual mapping FAILED: wrote \(String(format: "0x%X", testPattern)), read \(String(format: "0x%X", readBack ?? 0))", level: .error)
        }

        // Test 2: Verify RW and RX are at different virtual addresses
        if rwPtr != rxPtr {
            logStore.log("Distinct virtual addresses confirmed (RW != RX)", level: .success)
        } else {
            logStore.log("WARNING: RW and RX are at the same address", level: .error)
        }

        jit_region_destroy(region)
        logStore.log("Region destroyed. Dual mapping test complete.")
    }
}

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   /* ml658: see the note on the main body */
            List {
                Section("Requirements") {
                    guideRow(
                        icon: "cpu",
                        title: "JIT Compilation",
                        detail: "Required for x86 code translation. On iOS 26, StikDebug must stay attached — assign the 'universal' or 'MeloNX' JIT script to Madeira in StikDebug."
                    )
                    guideRow(
                        icon: "memorychip",
                        title: "Increased Memory Limit",
                        detail: "Raises the Jetsam memory threshold. Included in the app entitlements. If not detected, use GetMoreRam to inject it."
                    )
                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Extended Virtual Addressing",
                        detail: "Expands virtual address space to ~64GB. Required for large games. Must be injected via GetMoreRam (free accounts can't provision this)."
                    )
                }

                Section("Setup Steps") {
                    stepRow(number: 1, text: "Install Madeira via SideStore or Xcode")
                    stepRow(number: 2, text: "Install GetMoreRam and run it to inject memory entitlements into your App ID")
                    stepRow(number: 3, text: "Reinstall Madeira with the same IPA to apply injected entitlements")
                    stepRow(number: 4, text: "In StikDebug, assign the 'universal' JIT script to Madeira and launch it")
                    stepRow(number: 5, text: "Launch Madeira and tap 'Test JIT' to verify")
                }

                Section("About") {
                    Text("Madeira is a proof-of-concept for running x86 Windows games on iOS using FEX-Emu, Wine, and Metal-based graphics translation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// ml643 — LANDSCAPE TOUCH CONTROLS (pass 1: overlay, editor, persistence)
//
// This is the L2 layer from reference_swiftui_liquid_glass_ux_layers.md: glass
// elements composited over the game canvas, repositionable.
//
// 🔑 Everything here MUST live in its own UIWindow. MetalHostView is a raw
// window-level UIView above the whole SwiftUI hierarchy, so a control drawn in
// the normal content tree gets sliced off wherever it overlaps the game surface
// — and zIndex cannot fix that, because zIndex only orders siblings *within*
// SwiftUI. Same reason JoystickPadHost exists; see its comment.
// ============================================================================

/// What a control does when pressed. Codable with associated values so the
/// whole layout round-trips through JSON.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml645: Xbox button. NOT WIRED — see the panel.

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .pad(let n):      return n
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = true               { didSet { save() } }
    @Published var glassStyling = true          { didSet { save() } }
    @Published var editing = false              // transient, never persisted
    @Published var selected: UUID?              // transient

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-controls.json")
    }

    private struct Saved: Codable { var controls: [TouchControl]; var visible: Bool; var glassStyling: Bool? }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = s.controls
            visible  = s.visible
            glassStyling = s.glassStyling ?? true
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(Saved(controls: controls, visible: visible, glassStyling: glassStyling))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    /// ml644: does this WINDOW point land on something interactive?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect) -> Bool {
        // Adjusted fullscreen / menu button positions: Top bar buttons (gamecontroller, pencil/checkmark, etc.)
        // Padded generously; buttons auto-hide after 6s but remain tappable while invisible.
        let barW: CGFloat = 3 * 48 + 30
        if CGRect(x: bounds.midX - barW / 2 - 15, y: 0,
                  width: barW + 30, height: 74).contains(p) { return true }
        guard visible else { return false }
        for c in controls {
            let r = Self.baseDiameter * CGFloat(c.scale) / 2
            let cx = CGFloat(c.nx) * bounds.width
            let cy = CGFloat(c.ny) * bounds.height
            if hypot(p.x - cx, p.y - cy) <= r { return true }
        }
        return false
    }
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        // Edit mode owns the whole screen: drags and the scale pinch must not
        // leak through and swing the camera while you are arranging buttons.
        if m.editing { return super.hitTest(point, with: event) }
        // Portrait draws nothing here, so it must consume nothing.
        guard bounds.width > bounds.height else { return nil }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = false        // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
        fputs("[controls] ml644 overlay attached frame=\(window?.frame ?? .zero) " +
              "controls=\(TouchControlsModel.shared.controls.count)\n", stderr)
    }
}

struct TouchControlsOverlay: View {
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var pinchBase: Double?
    @State private var controlsVisible = true
    @State private var hideTimer: Timer?

    private func resetAutoHideTimer() {
        hideTimer?.invalidate()
        controlsVisible = true
        // Auto-hide fullscreen buttons after 6 seconds while keeping them tappable
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                if !m.editing {
                    controlsVisible = false
                }
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Landscape only; portrait keeps the existing key row and joystick.
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .top) {
                if landscape {
                    if m.visible || m.editing {
                        ForEach(m.controls) { c in
                            TouchControlButton(control: c, screen: geo.size)
                        }
                    }
                    topBar
                        .onAppear { resetAutoHideTimer() }
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            glassButton("gamecontroller", dim: !m.visible) {
                m.visible.toggle()
                resetAutoHideTimer()
            }
            glassButton(m.editing ? "checkmark" : "pencil") {
                m.editing.toggle()
                if !m.editing {
                    m.selected = nil
                    resetAutoHideTimer()
                } else {
                    controlsVisible = true
                    hideTimer?.invalidate()
                }
            }
            if m.editing {
                glassButton("plus") {
                    var c = TouchControl()
                    // Stagger, so repeated adds do not stack invisibly.
                    c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                    c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                    m.controls.append(c)
                    m.selected = c.id
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.top, 12)
        .opacity(controlsVisible || m.editing ? 1.0 : 0.02) // Auto-hide after 6s but remains tappable while invisible
        .animation(.easeInOut(duration: 0.28), value: controlsVisible)
        .animation(.easeInOut(duration: 0.22), value: m.editing)
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            resetAutoHideTimer()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            Image(systemName: system)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
                .frame(width: 44, height: 44)
                .background(
                    Group {
                        if m.glassStyling {
                            GlassShape(circle: true)
                        } else {
                            Circle().fill(Color.black.opacity(0.4))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

/// Shared glass backing using system ultraThinMaterial.
struct GlassShape: View {
    var circle = false
    @ViewBuilder var body: some View {
        if circle {
            Circle().fill(.ultraThinMaterial)
        } else {
            RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
        }
    }
}

struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var isDown = false
    @State private var dragBase: CGPoint?
    @State private var stickDir: Int = -1

    private var diameter: CGFloat { TouchControlsModel.baseDiameter * CGFloat(control.scale) }
    private var isStick: Bool { control.action.stickKeys != nil }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    var body: some View {
        ZStack {
            if control.action.stickKeys != nil {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
            } else {
                GlassShape(circle: true)
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(control.action.isPad ? 0.45
                                                    : (isDown ? 1.0 : 0.85)))
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(isSelected ? 0.95
                                                : (isStick ? 0 : 0.28)),
                                 lineWidth: isSelected ? 2 : 1))
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isDown)
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: stickDir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.editing {
                        m.selected = control.id
                        guard let i = m.index(of: control.id) else { return }
                        if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                        let b = dragBase ?? .zero
                        m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                        m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                    } else if let q = control.action.stickKeys {
                        isDown = true
                        applyStick(snap(v.translation), q)
                    } else if !isDown {
                        isDown = true
                        press(true)
                    }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let q = control.action.stickKeys {
                        applyStick(-1, q)          // release every held direction
                        isDown = false
                    } else if isDown {
                        isDown = false
                        press(false)
                    }
                }
        )
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < diameter * 0.22 { return -1 }        // deadzone scales with the control
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is. A blanket
    /// release/re-press would make a held direction stutter as the thumb
    /// wanders inside one sector.
    private func applyStick(_ next: Int, _ q: [Int32]) {
        guard next != stickDir else { return }
        let old = Set(stickKeys(stickDir, q)), new = Set(stickKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        if stickDir == -1, next != -1 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stickDir = next
    }

    /// Haptic on the DOWN edge only — a held movement key would otherwise buzz
    /// continuously for as long as you walk.
    private func press(_ down: Bool) {
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        switch control.action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle:
            if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows:
            break                                              // sticks drive themselves
        case .pad(let name):
            // Wire on-screen gamepad touch buttons to standard Windows bindings
            switch name {
            case "A": winios_post_key(0x20, down ? 1 : 0) // Space (Jump)
            case "B": winios_post_key(0x1B, down ? 1 : 0) // Esc (Back/Cancel)
            case "X": winios_post_key(0x45, down ? 1 : 0) // E (Interact/Action)
            case "Y": winios_post_key(0x52, down ? 1 : 0) // R (Reload)
            case "D↑": winios_post_key(0x26, down ? 1 : 0) // Up
            case "D↓": winios_post_key(0x28, down ? 1 : 0) // Down
            case "D←": winios_post_key(0x25, down ? 1 : 0) // Left
            case "D→": winios_post_key(0x27, down ? 1 : 0) // Right
            case "LB": winios_post_key(0x10, down ? 1 : 0) // Shift (Sprint)
            case "RB": winios_post_key(0x09, down ? 1 : 0) // Tab (Scoreboard/Inventory)
            case "LT": winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0) // Right Click
            case "RT": winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0) // Left Click
            case "L3": winios_post_key(0x11, down ? 1 : 0) // Ctrl (Crouch)
            case "R3": winios_post_key(0x46, down ? 1 : 0) // F (Melee/Flashlight)
            case "Menu": winios_post_key(0x1B, down ? 1 : 0) // Esc
            case "View": winios_post_key(0x09, down ? 1 : 0) // Tab
            case "Guide": if down { MetalBackedView.toggleKeyboard() }
            default: break
            }
        }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        let r  = TouchControlsModel.baseDiameter * CGFloat(control.scale) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gamepad layout: controls map to standard game keys (A=Space, B=Esc, X=E, Y=R, RT=Fire/Left Click, LT=Aim/Right Click, Sticks=WASD/Arrows).")
                .font(.system(size: 11))
                .foregroundStyle(.green.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            section("Face", [("A", .pad("A")), ("B", .pad("B")), ("X", .pad("X")), ("Y", .pad("Y"))])
            section("D-pad", [("D↑", .pad("D↑")), ("D↓", .pad("D↓")),
                              ("D←", .pad("D←")), ("D→", .pad("D→"))])
            section("Bumpers & triggers", [("LB", .pad("LB")), ("RB", .pad("RB")),
                                           ("LT", .pad("LT")), ("RT", .pad("RT"))])
            section("Sticks", [("LS", .pad("LS")), ("RS", .pad("RS")),
                               ("L3", .pad("L3")), ("R3", .pad("R3"))])
            section("System", [("Menu", .pad("Menu")), ("View", .pad("View")),
                               ("Guide", .pad("Guide"))])
        }
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}
