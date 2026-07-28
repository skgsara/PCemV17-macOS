import AppKit

/// Displays the emulator's framebuffer and forwards keyboard/mouse to the core.
///
/// Rendering: a 60 Hz timer pulls completed frames out of the bridge's staging
/// buffer (written by the core's blit thread) and hands them to the view's
/// CALayer as a CGImage. The pixels are PCem's native 32-bit BGRX layout, which
/// is exactly `noneSkipFirst + byteOrder32Little` — no conversion needed.
final class EmulatorView: NSView {

    private(set) var mouseCaptured = false
    private var displayTimer: Timer?
    /// Reusable buffer the bridge copies frames into (max 2048x2048x4).
    private let frameBuffer: UnsafeMutablePointer<UInt8>

    override init(frame frameRect: NSRect) {
        frameBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Int(pcem_bridge_frame_max_bytes()))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .nearest // crisp pixels, like a real CRT
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { frameBuffer.deallocate() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Frame display

    func startDisplayUpdates() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                            repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
    }

    private func updateFrame() {
        var w: Int32 = 0
        var h: Int32 = 0
        guard pcem_bridge_copy_frame(frameBuffer, &w, &h) != 0 else { return }

        let width = Int(w), height = Int(h)
        // Data(bytes:) copies, so the CGImage owns stable pixels while the
        // shared frameBuffer gets overwritten by the next frame.
        let data = Data(bytes: frameBuffer, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        layer?.contents = image
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Mouse release shortcuts (MacBooks have no middle click / End key):
        // Ctrl+Option+M, plus the classic Ctrl+End for external keyboards.
        let ctrlEnd = event.keyCode == 0x77 /* kVK_End */
            && event.modifierFlags.contains(.control)
        let ctrlOptM = event.keyCode == 0x2e /* kVK_ANSI_M */
            && event.modifierFlags.contains([.control, .option])
        if mouseCaptured && (ctrlEnd || ctrlOptM) {
            releaseMouse()
            return
        }
        // Let Cmd-key combos through to the menu bar (Cmd+Q etc.).
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        sendKey(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event.keyCode, down: false)
    }

    /// Modifier keys arrive as flagsChanged, not keyDown/keyUp.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let down: Bool
        switch event.keyCode {
        case 0x38, 0x3c: down = flags.contains(.shift)    // shifts
        case 0x3b, 0x3e: down = flags.contains(.control)  // controls
        case 0x3a, 0x3d: down = flags.contains(.option)   // options
        case 0x37, 0x36: down = flags.contains(.command)  // commands
        case 0x39:       down = flags.contains(.capsLock) // caps lock
        default: return
        }
        sendKey(event.keyCode, down: down)
    }

    private func sendKey(_ keyCode: UInt16, down: Bool) {
        let scancode = pcem_mac_keycode_to_pc(Int32(keyCode))
        if scancode >= 0 {
            pcem_bridge_key_event(scancode, down ? 1 : 0)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if mouseCaptured {
            pcem_bridge_mouse_button(0, 1)
        } else {
            captureMouse()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseCaptured { pcem_bridge_mouse_button(0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if mouseCaptured { pcem_bridge_mouse_button(1, 1) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseCaptured { pcem_bridge_mouse_button(1, 0) }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click releases the mouse, same as the wx UI.
        if mouseCaptured && event.buttonNumber == 2 { releaseMouse() }
    }

    override func mouseMoved(with event: NSEvent) { sendMouseDelta(event) }
    override func mouseDragged(with event: NSEvent) { sendMouseDelta(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouseDelta(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMouseDelta(event) }

    override func scrollWheel(with event: NSEvent) {
        guard mouseCaptured else { return }
        pcem_bridge_mouse_move(0, 0, Int32(event.scrollingDeltaY))
    }

    private func sendMouseDelta(_ event: NSEvent) {
        guard mouseCaptured else { return }
        pcem_bridge_mouse_move(Int32(event.deltaX), Int32(event.deltaY), 0)
    }

    // MARK: - Capture

    func captureMouse() {
        guard !mouseCaptured else { return }
        mouseCaptured = true
        // Disconnect cursor from mouse position: the pointer stays put and we
        // read raw deltas via NSEvent.deltaX/Y (SDL relative-mode equivalent).
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        NSCursor.hide()
        pcem_bridge_mouse_capture(1)
    }

    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        NSCursor.unhide()
        pcem_bridge_mouse_capture(0)
    }
}
