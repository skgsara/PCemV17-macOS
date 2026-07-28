import SwiftUI

/// M4 step 2: native replacement for the wx settings dialog (wx-config.c),
/// minus the hard-disc slot panels and device "Configure" sub-dialogs
/// (M4 step 3 / M5). Edits the RUNNING machine, like wx's IDM_CONFIG.
///
/// All state lives in a local copy of pcem_settings_t plus three strings
/// (hdd controller / lpt device / cd model). Lists come from the bridge,
/// filtered for the selected model exactly like the wx recalc_*_list
/// functions; changing the model re-queries and clamps (port of wx's
/// on_model_changed). Apply goes through pcem_bridge_settings_apply, which
/// dirty-checks, reboots and saves like config_dlgsave.
struct SettingsView: View {

    /// nil = edit the RUNNING machine (live mode; Apply may reboot).
    /// non-nil = edit that config file without booting it (the machine
    /// manager's Configure… flow; Apply just saves).
    var editMachine: String?
    var onApply: () -> Void
    var onCancel: () -> Void

    @State private var s = pcem_settings_t()
    @State private var hddController = ""
    @State private var lptDevice = ""
    @State private var cdModel = ""
    @State private var confirmReboot = false

    // Integer-valued picker option (value = the core's own index/number).
    private struct Opt: Identifiable {
        let id: Int
        let label: String
        let value: Int32
    }
    // String-valued picker option (hdd/lpt/cd travel as internal names).
    private struct SOpt: Identifiable {
        let id: Int
        let label: String
        let value: String
    }

    // Fixed option sets (same strings as the wx dialog, pc.xrc/wx-config.c).
    private let videoSpeedNames = ["Default", "8-bit", "Slow 16-bit",
        "Fast 16-bit", "Slow VLB/PCI", "Mid  VLB/PCI", "Fast VLB/PCI"]
    private let fddTypeNames = ["None", "5.25\" 360k", "5.25\" 1.2M",
        "5.25\" 1.2M Dual RPM", "3.5\" 720k", "3.5\" 1.44M",
        "3.5\" 1.44M 3-Mode", "3.5\" 2.88M"]
    private let waitstateNames = ["System default", "0 W/S", "1 W/S", "2 W/S",
        "3 W/S", "4 W/S", "5 W/S", "6 W/S", "7 W/S"]

    var body: some View {
        VStack(spacing: 0) {
            // Tabs mirror the wx dialog's notebook (pc.xrc ConfigureDlg).
            TabView {
                Form { machineRows }.tabItem { Text("Machine") }
                Form { videoRows }.tabItem { Text("Video") }
                Form { soundRows }.tabItem { Text("Sound") }
                Form { drivesRows }.tabItem { Text("Drives") }
                Form { inputRows }.tabItem { Text("Input") }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    pcem_bridge_settings_cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") { applyTapped() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
        .onAppear(perform: load)
        .alert("This will reset PCem!", isPresented: $confirmReboot) {
            Button("Reset and Apply") { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The machine will reboot with the new settings.")
        }
    }

    // MARK: - Tab contents

    @ViewBuilder private var machineRows: some View {
            Picker("Machine", selection: $s.model) {
                ForEach(modelOptions()) { o in Text(o.label).tag(o.value) }
            }
            .onChange(of: s.model) { _ in modelChanged() }

            if pcem_bridge_cpu_manu_count(s.model) > 1 {
                Picker("CPU manufacturer", selection: $s.cpu_manufacturer) {
                    ForEach(cpuManuOptions()) { o in Text(o.label).tag(o.value) }
                }
                .onChange(of: s.cpu_manufacturer) { _ in cpuChanged() }
            }

            Picker("CPU", selection: $s.cpu) {
                ForEach(cpuOptions()) { o in Text(o.label).tag(o.value) }
            }
            .onChange(of: s.cpu) { _ in cpuChanged() }

            if pcem_bridge_fpu_count(s.model, s.cpu_manufacturer, s.cpu) > 1 {
                Picker("FPU", selection: $s.fpu_index) {
                    ForEach(fpuOptions()) { o in Text(o.label).tag(o.value) }
                }
            }

            let flags = pcem_bridge_cpu_dynarec_flags(s.model, s.cpu_manufacturer, s.cpu)
            Toggle("Dynamic recompiler", isOn: $s.cpu_use_dynarec.bool)
                .disabled(flags & 1 == 0 || flags & 2 != 0)

            HStack {
                Stepper("Memory", value: memBinding,
                        in: pcem_bridge_model_min_ram(s.model)...pcem_bridge_model_max_ram(s.model),
                        step: Int(pcem_bridge_model_ram_granularity(s.model)))
                Text("\(memBinding.wrappedValue) \(usesMb ? "MB" : "KB")")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }

            Picker("Waitstates", selection: $s.cpu_waitstates) {
                ForEach(Array(waitstateNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(Int32(i))
                }
            }
            .disabled(pcem_bridge_cpu_waitstates_supported(
                s.model, s.cpu_manufacturer, s.cpu) == 0)

            Toggle("Sync time to host", isOn: $s.enable_sync.bool)
    }

    @ViewBuilder private var videoRows: some View {
            Picker("Device", selection: $s.gfxcard) {
                ForEach(videoOptions()) { o in Text(o.label).tag(o.value) }
            }
            .disabled(pcem_bridge_model_has_fixed_gfx(s.model) != 0)

            Picker("Speed", selection: $s.video_speed) {
                ForEach(Array(videoSpeedNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(Int32(i - 1)) // -1 = Default, 0..5 speeds
                }
            }

            Toggle("Voodoo Graphics", isOn: $s.voodoo.bool)
                .disabled(pcem_bridge_model_has_pci(s.model) == 0)
    }

    @ViewBuilder private var soundRows: some View {
            Picker("Device", selection: $s.sound_card) {
                ForEach(soundOptions()) { o in Text(o.label).tag(o.value) }
            }
            Toggle("CMS / Game Blaster", isOn: $s.gameblaster.bool)
            Toggle("Gravis Ultrasound", isOn: $s.gus.bool)
            Toggle("Innovation SSI-2001", isOn: $s.ssi2001.bool)
            Picker("LPT Device", selection: $lptDevice) {
                ForEach(lptOptions()) { o in Text(o.label).tag(o.value) }
            }
    }

    /// C fixed-size arrays import as tuples, so the FDD pickers need an
    /// explicit get/set binding instead of `$s.fdd_type.0`.
    private func fddBinding(_ drive: Int) -> Binding<Int32> {
        Binding(
            get: { drive == 0 ? s.fdd_type.0 : s.fdd_type.1 },
            set: { if drive == 0 { s.fdd_type.0 = $0 } else { s.fdd_type.1 = $0 } })
    }

    @ViewBuilder private var drivesRows: some View {
            Picker("FDD1", selection: fddBinding(0)) {
                ForEach(Array(fddTypeNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(Int32(i))
                }
            }
            Picker("FDD2", selection: fddBinding(1)) {
                ForEach(Array(fddTypeNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(Int32(i))
                }
            }
            Picker("HD Controller", selection: $hddController) {
                ForEach(hddOptions()) { o in Text(o.label).tag(o.value) }
            }
            .onChange(of: hddController) { _ in hddChanged() }
            Picker("CD Model", selection: $cdModel) {
                ForEach(cdModelOptions()) { o in Text(o.label).tag(o.value) }
            }
            .onChange(of: cdModel) { _ in cdModelChanged() }
            Picker("CD Speed", selection: $s.cd_speed) {
                ForEach(cdSpeedOptions()) { o in Text(o.label).tag(o.value) }
            }
            .disabled(pcem_bridge_cd_model_fixed_speed(cdModel) != -1)
    }

    @ViewBuilder private var inputRows: some View {
            Picker("Mouse", selection: $s.mouse_type) {
                ForEach(mouseOptions()) { o in Text(o.label).tag(o.value) }
            }
            Picker("Joystick", selection: $s.joystick_type) {
                ForEach(joystickOptions()) { o in Text(o.label).tag(o.value) }
            }
    }

    // MARK: - Bridge list queries

    private func modelOptions() -> [Opt] {
        (0..<pcem_bridge_settings_model_count()).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_settings_model_name(i)),
                value: pcem_bridge_settings_model_index(i))
        }
    }

    private func cpuManuOptions() -> [Opt] {
        (0..<pcem_bridge_cpu_manu_count(s.model)).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_cpu_manu_name(s.model, i)),
                value: i)
        }
    }

    private func cpuOptions() -> [Opt] {
        (0..<pcem_bridge_cpu_count(s.model, s.cpu_manufacturer)).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_cpu_name(s.model, s.cpu_manufacturer, i)),
                value: i)
        }
    }

    private func fpuOptions() -> [Opt] {
        (0..<pcem_bridge_fpu_count(s.model, s.cpu_manufacturer, s.cpu)).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_fpu_name(s.model, s.cpu_manufacturer, s.cpu, i)),
                value: i)
        }
    }

    private func videoOptions() -> [Opt] {
        (0..<pcem_bridge_video_count(s.model)).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_video_name(s.model, i)),
                value: pcem_bridge_video_gfxcard(s.model, i))
        }
    }

    private func soundOptions() -> [Opt] {
        (0..<pcem_bridge_sound_count(s.model)).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_sound_name(s.model, i)),
                value: pcem_bridge_sound_card(s.model, i))
        }
    }

    private func hddOptions() -> [SOpt] {
        (0..<pcem_bridge_hdd_count(s.model)).map { i in
            SOpt(id: Int(i), label: String(cString: pcem_bridge_hdd_name(s.model, i)),
                 value: String(cString: pcem_bridge_hdd_internal_name(s.model, i)))
        }
    }

    private func lptOptions() -> [SOpt] {
        (0..<pcem_bridge_lpt_count()).map { i in
            SOpt(id: Int(i), label: String(cString: pcem_bridge_lpt_name(i)),
                 value: String(cString: pcem_bridge_lpt_internal_name(i)))
        }
    }

    private func mouseOptions() -> [Opt] {
        (0..<pcem_bridge_mouse_count(s.model)).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_mouse_name(s.model, i)),
                value: pcem_bridge_mouse_type(s.model, i))
        }
    }

    private func joystickOptions() -> [Opt] {
        (0..<pcem_bridge_joystick_count()).map { i in
            Opt(id: Int(i), label: String(cString: pcem_bridge_joystick_name(i)),
                value: i)
        }
    }

    private func cdModelOptions() -> [SOpt] {
        (0..<pcem_bridge_cd_model_count(hddController)).map { i in
            SOpt(id: Int(i), label: String(cString: pcem_bridge_cd_model_name(hddController, i)),
                 value: String(cString: pcem_bridge_cd_model_name(hddController, i)))
        }
    }

    private func cdSpeedOptions() -> [Opt] {
        (0..<pcem_bridge_cd_speed_count()).map { i in
            let v = pcem_bridge_cd_speed_value(i)
            return Opt(id: Int(i), label: "\(v)X", value: v)
        }
    }

    // MARK: - Memory display units (MB for AT machines with fine granularity)

    private var usesMb: Bool { pcem_bridge_model_uses_mb(s.model) != 0 }

    private var memBinding: Binding<Int32> {
        Binding(
            get: { usesMb ? s.mem_size / 1024 : s.mem_size },
            set: { s.mem_size = usesMb ? $0 * 1024 : $0 })
    }

    // MARK: - Change handlers (port of wx on_model_changed clamping)

    private func modelChanged() {
        if s.cpu_manufacturer >= pcem_bridge_cpu_manu_count(s.model) {
            s.cpu_manufacturer = 0
        }
        cpuChanged()

        // Video: keep the card if still valid, else first entry.
        let vids = videoOptions()
        if pcem_bridge_model_has_fixed_gfx(s.model) != 0 {
            s.gfxcard = -1 // GFX_BUILTIN
        } else if !vids.contains(where: { $0.value == s.gfxcard }) {
            s.gfxcard = vids.first?.value ?? 0
        }

        let snds = soundOptions()
        if !snds.contains(where: { $0.value == s.sound_card }) {
            s.sound_card = snds.first?.value ?? 0
        }

        // HDD controller: keep if valid, else the wx default rule.
        let hdds = hddOptions()
        if !hdds.contains(where: { $0.value == hddController }) {
            hddController = hdds.first?.value ?? "none"
        }
        hddChanged()

        let mice = mouseOptions()
        if !mice.contains(where: { $0.value == s.mouse_type }) {
            s.mouse_type = mice.first?.value ?? 0
        }

        if pcem_bridge_model_has_pci(s.model) == 0 { s.voodoo = 0 }
    }

    private func cpuChanged() {
        if s.cpu >= pcem_bridge_cpu_count(s.model, s.cpu_manufacturer) {
            s.cpu = 0
        }
        s.fpu_index = 0
        let flags = pcem_bridge_cpu_dynarec_flags(s.model, s.cpu_manufacturer, s.cpu)
        if flags & 2 != 0 {
            s.cpu_use_dynarec = 1 // required
        } else if flags & 1 == 0 {
            s.cpu_use_dynarec = 0 // unsupported
        }
    }

    /// CD model list depends on the controller interface (IDE/SCSI).
    private func hddChanged() {
        let cds = cdModelOptions()
        if !cds.contains(where: { $0.value == cdModel }) {
            cdModel = cds.first?.value ?? ""
        }
        cdModelChanged()
    }

    private func cdModelChanged() {
        let fixed = pcem_bridge_cd_model_fixed_speed(cdModel)
        if fixed != -1 { s.cd_speed = fixed }
    }

    // MARK: - Load / apply

    private func load() {
        if let editMachine {
            // Edit mode: loads the config into the core's globals without
            // booting it; Apply saves back to the same file (no reboot).
            pcem_bridge_settings_begin_edit(editMachine)
        } else {
            pcem_bridge_settings_begin() // pauses emulation
        }
        pcem_bridge_settings_get(&s)
        hddController = String(cString: pcem_bridge_settings_hdd_controller())
        lptDevice = String(cString: pcem_bridge_settings_lpt1_device())
        cdModel = String(cString: pcem_bridge_settings_cd_model())
    }

    private func applyTapped() {
        if pcem_bridge_settings_would_reboot(&s, hddController, lptDevice) != 0 {
            confirmReboot = true
        } else {
            apply()
        }
    }

    private func apply() {
        pcem_bridge_settings_apply(&s, hddController, lptDevice, cdModel)
        onApply()
    }
}

/// C Int32 fields used as SwiftUI Toggle bindings.
private extension Int32 {
    var bool: Bool {
        get { self != 0 }
        set { self = newValue ? 1 : 0 }
    }
}
