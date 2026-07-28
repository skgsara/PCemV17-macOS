import AppKit
import UniformTypeIdentifiers

/// Native macOS shell for PCem. Boots the emulator core through the C bridge
/// (pcem_bridge.h) and provides the window, menus, and machine picker.
///
/// The menu bar mirrors the wx app's right-click context menu (pc.xrc):
/// System, Disc, CD-ROM, Cassette, Sound — plus native additions
/// (Machine picker, View). Machine *configuration* still happens in the wx
/// build (M4 will move it here).
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private let emulatorView = EmulatorView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    private var machineMenu: NSMenu!
    private var scaleMenuItems = [NSMenuItem]()
    /// Last emulated resolution seen; the window is resized on mode changes.
    private var videoSize = NSSize(width: 640, height: 480)
    /// Window size = emulated resolution × this factor (integer = crisp pixels).
    private var windowScale = 1

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Startup

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.delegate = self
        window.contentView = emulatorView
        window.title = "PCem"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(emulatorView)

        // Release the mouse if the user switches apps while captured.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification, object: window)

        installBridgeCallbacks()

        if pcem_bridge_start() == 0 {
            let alert = NSAlert()
            alert.messageText = "No ROMs present"
            alert.informativeText =
                "PCem needs at least one romset in the roms folder."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        rebuildMachineMenu()
        emulatorView.startDisplayUpdates()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The bridge calls these from arbitrary threads; they arrive on the main
    /// queue already (the bridge dispatches them there).
    private func installBridgeCallbacks() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        pcem_bridge_set_title_callback({ ctx, title in
            guard let ctx, let title else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx)
                .takeUnretainedValue().window.title = String(cString: title)
        }, ctx)

        pcem_bridge_set_video_size_callback({ ctx, w, h in
            guard let ctx else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx)
                .takeUnretainedValue().videoSizeChanged(Int(w), Int(h))
        }, ctx)

        pcem_bridge_set_stop_callback({ ctx in
            guard let ctx else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx)
                .takeUnretainedValue().guestPoweredOff()
        }, ctx)
    }

    // MARK: - Window sizing

    /// The guest changed resolution: remember it and re-fit the window.
    private func videoSizeChanged(_ w: Int, _ h: Int) {
        let newSize = NSSize(width: w, height: h)
        guard newSize != videoSize else { return }
        videoSize = newSize
        applyWindowSize()
    }

    /// Window size = emulated resolution × windowScale, clamped to the screen.
    private func applyWindowSize() {
        var content = NSSize(width: Int(videoSize.width) * windowScale,
                             height: Int(videoSize.height) * windowScale)
        if let screen = window.screen {
            let maxSize = screen.visibleFrame.size
            content.width = min(content.width, maxSize.width * 0.9)
            content.height = min(content.height, maxSize.height * 0.9)
        }
        window.setContentSize(content)
    }

    private func guestPoweredOff() {
        pcem_bridge_stop()
        window.title = "PCem (stopped)"
    }

    @objc private func windowDidResignKey() {
        emulatorView.releaseMouse()
    }

    // MARK: - Menus

    private func buildMenus() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PCem",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Machine (native: list of saved configs)
        let machineMenuItem = NSMenuItem()
        mainMenu.addItem(machineMenuItem)
        machineMenu = NSMenu(title: "Machine")
        machineMenuItem.submenu = machineMenu

        // System (wx context menu: Hard Reset / Ctrl+Alt+Del / Shutdown)
        let systemMenuItem = NSMenuItem()
        mainMenu.addItem(systemMenuItem)
        let systemMenu = NSMenu(title: "System")
        systemMenu.addItem(withTitle: "Reset", action: #selector(resetSoft),
                           keyEquivalent: "r")
        systemMenu.addItem(withTitle: "Hard Reset", action: #selector(resetHard),
                           keyEquivalent: "R")
        systemMenu.addItem(withTitle: "Ctrl+Alt+Del", action: #selector(resetCAD),
                           keyEquivalent: "")
        systemMenu.addItem(.separator())
        systemMenu.addItem(withTitle: "Pause", action: #selector(togglePause),
                           keyEquivalent: "p")
        systemMenu.addItem(.separator())
        systemMenu.addItem(withTitle: "Shut Down Machine",
                           action: #selector(shutdownMachine), keyEquivalent: "")
        systemMenuItem.submenu = systemMenu

        // Disc (wx context menu: floppies, BPB, ZIP)
        let discMenuItem = NSMenuItem()
        mainMenu.addItem(discMenuItem)
        let discMenu = NSMenu(title: "Disc")
        discMenu.addItem(withTitle: "Change drive A:…",
                         action: #selector(mountFloppyA), keyEquivalent: "")
        discMenu.addItem(withTitle: "Change drive B:…",
                         action: #selector(mountFloppyB), keyEquivalent: "")
        discMenu.addItem(withTitle: "Eject drive A:",
                         action: #selector(ejectFloppyA), keyEquivalent: "")
        discMenu.addItem(withTitle: "Eject drive B:",
                         action: #selector(ejectFloppyB), keyEquivalent: "")
        discMenu.addItem(.separator())
        discMenu.addItem(withTitle: "Disable BPB checking",
                         action: #selector(toggleBPB), keyEquivalent: "")
        discMenu.addItem(.separator())
        discMenu.addItem(withTitle: "Load ZIP drive…",
                         action: #selector(loadZIP), keyEquivalent: "")
        discMenu.addItem(withTitle: "Eject ZIP drive",
                         action: #selector(ejectZIP), keyEquivalent: "")
        discMenuItem.submenu = discMenu

        // CD-ROM (wx context menu: Load image… / Empty)
        let cdMenuItem = NSMenuItem()
        mainMenu.addItem(cdMenuItem)
        let cdMenu = NSMenu(title: "CD-ROM")
        cdMenu.addItem(withTitle: "Load image…",
                       action: #selector(mountCD), keyEquivalent: "")
        cdMenu.addItem(withTitle: "Empty",
                       action: #selector(ejectCD), keyEquivalent: "")
        cdMenuItem.submenu = cdMenu

        // Cassette (only used by PCjr/Tandy machines, but harmless to show)
        let cassetteMenuItem = NSMenuItem()
        mainMenu.addItem(cassetteMenuItem)
        let cassetteMenu = NSMenu(title: "Cassette")
        cassetteMenu.addItem(withTitle: "Load tapefile…",
                             action: #selector(loadCassette), keyEquivalent: "")
        cassetteMenu.addItem(withTitle: "Eject tape",
                             action: #selector(ejectCassette), keyEquivalent: "")
        cassetteMenuItem.submenu = cassetteMenu

        // View (native equivalent of the wx Video menu: window scale, mouse)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        for scale in 1...3 {
            let item = NSMenuItem(title: "Window Size \(scale)×",
                                  action: #selector(selectScale(_:)),
                                  keyEquivalent: "")
            item.tag = scale
            item.state = (scale == windowScale) ? .on : .off
            scaleMenuItems.append(item)
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let releaseItem = NSMenuItem(title: "Release Mouse",
                                     action: #selector(releaseMouseAction),
                                     keyEquivalent: "m")
        releaseItem.keyEquivalentModifierMask = [.control, .option]
        viewMenu.addItem(releaseItem)
        viewMenuItem.submenu = viewMenu

        // Sound (wx context menu: buffer length / output level)
        let soundMenuItem = NSMenuItem()
        mainMenu.addItem(soundMenuItem)
        let soundMenu = NSMenu(title: "Sound")
        let bufItem = NSMenuItem()
        bufItem.title = "Buffer length"
        let bufMenu = NSMenu()
        for ms in [50, 100, 200, 400] {
            let item = NSMenuItem(title: "\(ms) ms",
                                  action: #selector(selectBufferLength(_:)),
                                  keyEquivalent: "")
            item.tag = ms
            bufMenu.addItem(item)
        }
        bufItem.submenu = bufMenu
        soundMenu.addItem(bufItem)
        let gainItem = NSMenuItem()
        gainItem.title = "Output level"
        let gainMenu = NSMenu()
        for db in stride(from: 0, through: 18, by: 2) {
            let item = NSMenuItem(title: db == 0 ? "Normal" : "+\(db) dB",
                                  action: #selector(selectGain(_:)),
                                  keyEquivalent: "")
            item.tag = db
            gainMenu.addItem(item)
        }
        gainItem.submenu = gainMenu
        soundMenu.addItem(gainItem)
        soundMenuItem.submenu = soundMenu

        NSApp.mainMenu = mainMenu
    }

    /// One menu item per *.cfg in the configs folder; checkmark on the booted one.
    private func rebuildMachineMenu() {
        machineMenu.removeAllItems()
        let current = pcem_bridge_current_config_name().map { String(cString: $0) }
        for i in 0..<pcem_bridge_config_count() {
            guard let cName = pcem_bridge_config_name(i) else { continue }
            let name = String(cString: cName)
            let item = NSMenuItem(title: name,
                                  action: #selector(selectMachine(_:)),
                                  keyEquivalent: "")
            item.tag = Int(i)
            item.state = (name == current) ? .on : .off
            machineMenu.addItem(item)
        }
    }

    /// Keeps checkmarks (BPB, sound radios) and enable states (eject items)
    /// in sync with the emulator's actual state every time a menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(ejectFloppyA):
            return pcem_bridge_floppy_path(0).pointee != 0
        case #selector(ejectFloppyB):
            return pcem_bridge_floppy_path(1).pointee != 0
        case #selector(ejectCD):
            return pcem_bridge_cd_is_empty() == 0
        case #selector(toggleBPB):
            menuItem.state = (pcem_bridge_get_bpb_disable() != 0) ? .on : .off
            return true
        case #selector(selectBufferLength(_:)):
            menuItem.state =
                (pcem_bridge_get_sound_buf_len() == menuItem.tag) ? .on : .off
            return true
        case #selector(selectGain(_:)):
            menuItem.state =
                (pcem_bridge_get_sound_gain() == menuItem.tag) ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - Open panels

    /// Shows an open panel filtered to the given extensions; returns the path.
    private func chooseFile(title: String, extensions: [String]) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    // MARK: - Menu actions: System

    @objc private func resetSoft() { pcem_bridge_reset(0) }
    @objc private func resetHard() { pcem_bridge_reset(1) }
    @objc private func resetCAD()  { pcem_bridge_reset(2) }

    @objc private func togglePause(_ sender: NSMenuItem) {
        let nowPaused = pcem_bridge_is_paused() == 0
        pcem_bridge_pause(nowPaused ? 1 : 0)
        sender.state = nowPaused ? .on : .off
    }

    @objc private func shutdownMachine() {
        guestPoweredOff()
    }

    // MARK: - Menu actions: Disc / CD-ROM / Cassette

    @objc private func mountFloppyA() { mountFloppy(drive: 0) }
    @objc private func mountFloppyB() { mountFloppy(drive: 1) }

    private func mountFloppy(drive: Int32) {
        if let path = chooseFile(title: "Select disc image",
                                 extensions: ["img", "ima", "fdi"]) {
            pcem_bridge_mount_floppy(drive, path)
        }
    }

    @objc private func ejectFloppyA() { pcem_bridge_eject_floppy(0) }
    @objc private func ejectFloppyB() { pcem_bridge_eject_floppy(1) }

    @objc private func toggleBPB(_ sender: NSMenuItem) {
        pcem_bridge_set_bpb_disable(pcem_bridge_get_bpb_disable() == 0 ? 1 : 0)
    }

    @objc private func loadZIP() {
        if let path = chooseFile(title: "Select ZIP disc image",
                                 extensions: ["img"]) {
            pcem_bridge_zip_load(path)
        }
    }

    @objc private func ejectZIP() { pcem_bridge_zip_eject() }

    @objc private func mountCD() {
        if let path = chooseFile(title: "Select CD-ROM image",
                                 extensions: ["iso", "cue"]) {
            pcem_bridge_mount_cd_image(path)
        }
    }

    @objc private func ejectCD() { pcem_bridge_eject_cd() }

    @objc private func loadCassette() {
        if let path = chooseFile(title: "Select tape image",
                                 extensions: ["pzxi", "pzx"]) {
            pcem_bridge_cassette_load(path)
        }
    }

    @objc private func ejectCassette() { pcem_bridge_cassette_eject() }

    // MARK: - Menu actions: View / Sound / Machine

    @objc private func selectScale(_ sender: NSMenuItem) {
        windowScale = sender.tag
        for item in scaleMenuItems {
            item.state = (item.tag == windowScale) ? .on : .off
        }
        applyWindowSize()
    }

    @objc private func releaseMouseAction() {
        emulatorView.releaseMouse()
    }

    @objc private func selectBufferLength(_ sender: NSMenuItem) {
        pcem_bridge_set_sound_buf_len(Int32(sender.tag))
    }

    @objc private func selectGain(_ sender: NSMenuItem) {
        pcem_bridge_set_sound_gain(Int32(sender.tag))
    }

    @objc private func selectMachine(_ sender: NSMenuItem) {
        emulatorView.releaseMouse()
        pcem_bridge_use_config(Int32(sender.tag))
        rebuildMachineMenu()
    }

    // MARK: - Shutdown

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pcem_bridge_quit()
    }
}
