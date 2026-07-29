import SwiftUI
import AppKit

/// M4 step 2: native replacement for the wx settings dialog (wx-config.c);
/// M4 step 3 added the Hard Discs tab (hdconf_dlgproc port); M5 slice 1 added
/// the device "Configure…" buttons (DeviceConfigView). Edits the RUNNING
/// machine in live mode, like wx's IDM_CONFIG.
///
/// All state lives in a local copy of pcem_settings_t plus three strings
/// (hdd controller / lpt device / cd model) and the HD slot array. Lists
/// come from the bridge, filtered for the selected model exactly like the
/// wx recalc_*_list functions; changing the model re-queries and clamps
/// (port of wx's on_model_changed). Apply goes through
/// pcem_bridge_settings_apply, which dirty-checks, reboots and saves like
/// config_dlgsave.
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

    // HD slot state (M4 step 3). Mirrored to the bridge's pending state by
    // syncHD() at Apply time; type per slot is derived from the channels,
    // like wx's update_hdd_cdrom.
    private struct HDSlotState {
        var spt = 0, hpc = 0, cyl = 0
        var path = ""
    }
    @State private var hdSlots = [HDSlotState](repeating: HDSlotState(),
                                               count: Int(PCEM_HD_SLOTS))
    @State private var cdromChannel = -1
    @State private var zipChannel = -1

    // Sheets / alerts for the HD rows.
    private struct NewImageRequest: Identifiable {
        let id = UUID()
        let slot: Int
    }
    private struct ProbeResult: Identifiable {
        let id = UUID()
        let slot: Int
        let path: String
        let spt: Int, hpc: Int, cyl: Int
    }
    @State private var newImageRequest: NewImageRequest?
    @State private var probeResult: ProbeResult?
    @State private var showError = false
    @State private var errorText = ""
    @State private var tsFixProbe: ProbeResult? // timestamp-mismatch pending probe
    @State private var showTsFix = false

    // Device "Configure…" sheet (M5 slice 1, port of wx's IDC_CONFIGURE*).
    private struct DeviceConfigRequest: Identifiable {
        let id = UUID()
        let which: Int32      // PCEM_DEVCFG_*
        let primary: Int32    // pending model / gfxcard / sound card selection
        let model: Int32      // pending model (video romset resolution)
        let hddInternal: String
    }
    @State private var deviceConfig: DeviceConfigRequest?

    /// wx enablement: the resolved device has a non-empty config. Recomputed
    /// from the tab's pending selection on every render, like the wx
    /// recalc_*_list handlers.
    private func devcfgHasConfig(_ which: Int32, primary: Int32 = 0,
                                 model: Int32 = 0, hdd: String = "") -> Bool {
        hdd.withCString { pcem_bridge_devcfg_has_config(which, primary, model, $0) != 0 }
    }

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
                hardDiscRows.tabItem { Text("Hard Discs") }
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
        .sheet(item: $newImageRequest) { req in
            NewHardDiscSheet { path, spt, hpc, cyl in
                hdSlots[req.slot] = HDSlotState(spt: spt, hpc: hpc, cyl: cyl, path: path)
            }
        }
        .sheet(item: $probeResult) { result in
            ConfirmGeometrySheet(path: result.path, initialSpt: result.spt,
                                 initialHpc: result.hpc, initialCyl: result.cyl) { path, spt, hpc, cyl in
                hdSlots[result.slot] = HDSlotState(spt: spt, hpc: hpc, cyl: cyl, path: path)
            }
        }
        .sheet(item: $deviceConfig) { req in
            DeviceConfigView(which: req.which, primary: req.primary,
                             model: req.model, hddInternal: req.hddInternal)
        }
        .alert("PCem error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
        .alert("PCem error", isPresented: $showTsFix) {
            Button("Fix") { fixTimestamp() }
            Button("Don't fix", role: .cancel) {}
        } message: {
            Text("WARNING: VHD PARENT/CHILD TIMESTAMPS DO NOT MATCH!\n\n" +
                 "This could indicate that the parent image was modified after this VHD was created.\n\n" +
                 "This could also happen if the VHD files were moved/copied, or the differencing VHD was created with DiskPart.\n\n" +
                 "Do you wish to fix this error after a file copy or DiskPart creation?")
        }
    }

    // MARK: - Tab contents

    @ViewBuilder private var machineRows: some View {
            HStack {
                Picker("Machine", selection: $s.model) {
                    ForEach(modelOptions()) { o in Text(o.label).tag(o.value) }
                }
                .onChange(of: s.model) { _ in modelChanged() }
                Button("Configure…") {
                    deviceConfig = DeviceConfigRequest(which: PCEM_DEVCFG_MACHINE,
                                                       primary: 0, model: s.model,
                                                       hddInternal: "")
                }
                .disabled(!devcfgHasConfig(PCEM_DEVCFG_MACHINE, model: s.model))
            }

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
            HStack {
                Picker("Device", selection: $s.gfxcard) {
                    ForEach(videoOptions()) { o in Text(o.label).tag(o.value) }
                }
                .disabled(pcem_bridge_model_has_fixed_gfx(s.model) != 0)
                Button("Configure…") {
                    deviceConfig = DeviceConfigRequest(which: PCEM_DEVCFG_VIDEO,
                                                       primary: s.gfxcard, model: s.model,
                                                       hddInternal: "")
                }
                .disabled(!devcfgHasConfig(PCEM_DEVCFG_VIDEO, primary: s.gfxcard,
                                           model: s.model))
            }

            Picker("Speed", selection: $s.video_speed) {
                ForEach(Array(videoSpeedNames.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(Int32(i - 1)) // -1 = Default, 0..5 speeds
                }
            }

            HStack {
                Toggle("Voodoo Graphics", isOn: $s.voodoo.bool)
                    .disabled(pcem_bridge_model_has_pci(s.model) == 0)
                Spacer()
                Button("Configure…") {
                    deviceConfig = DeviceConfigRequest(which: PCEM_DEVCFG_VOODOO,
                                                       primary: 0, model: s.model,
                                                       hddInternal: "")
                }
                // wx gates IDC_CONFIGUREVOODOO on MODEL_PCI, like the toggle.
                .disabled(pcem_bridge_model_has_pci(s.model) == 0)
            }
    }

    @ViewBuilder private var soundRows: some View {
            HStack {
                Picker("Device", selection: $s.sound_card) {
                    ForEach(soundOptions()) { o in Text(o.label).tag(o.value) }
                }
                Button("Configure…") {
                    deviceConfig = DeviceConfigRequest(which: PCEM_DEVCFG_SOUND,
                                                       primary: s.sound_card, model: s.model,
                                                       hddInternal: "")
                }
                .disabled(!devcfgHasConfig(PCEM_DEVCFG_SOUND, primary: s.sound_card))
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
            HStack {
                Picker("HD Controller", selection: $hddController) {
                    ForEach(hddOptions()) { o in Text(o.label).tag(o.value) }
                }
                .onChange(of: hddController) { _ in hddChanged() }
                Button("Configure…") {
                    deviceConfig = DeviceConfigRequest(which: PCEM_DEVCFG_HDD,
                                                       primary: 0, model: s.model,
                                                       hddInternal: hddController)
                }
                .disabled(!devcfgHasConfig(PCEM_DEVCFG_HDD, hdd: hddController))
            }
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

    // MARK: - Hard Discs tab (M4 step 3, port of hdconf_dlgproc)

    /// 0 = hard drive, 1 = CD-ROM, 2 = ZIP (wx update_hdd_cdrom).
    private func slotType(_ i: Int) -> Int {
        if cdromChannel == i { return 1 }
        if zipChannel == i { return 2 }
        return 0
    }

    /// Port of hd_combodrivetype: CD-ROM and ZIP channels are exclusive.
    private func setSlotType(_ i: Int, _ type: Int) {
        switch type {
        case 1:
            cdromChannel = i
            if zipChannel == i { zipChannel = -1 }
        case 2:
            zipChannel = i
            if cdromChannel == i { cdromChannel = -1 }
        default:
            if cdromChannel == i { cdromChannel = -1 }
            if zipChannel == i { zipChannel = -1 }
        }
    }

    private func slotTypeBinding(_ i: Int) -> Binding<Int> {
        Binding(get: { slotType(i) }, set: { setSlotType(i, $0) })
    }

    @ViewBuilder private var hardDiscRows: some View {
        // MFM controllers only take hard discs (wx hdconf_update).
        let mfm = pcem_bridge_hdd_is_mfm(hddController) != 0
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<Int(PCEM_HD_SLOTS), id: \.self) { i in
                    GroupBox("Drive \(i)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Type", selection: slotTypeBinding(i)) {
                                Text("Hard drive").tag(0)
                                Text("CD-ROM").tag(1)
                                Text("ZIP").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .disabled(mfm)

                            if slotType(i) == 0 {
                                HStack {
                                    TextField("Sectors", value: $hdSlots[i].spt, format: .number)
                                    TextField("Heads", value: $hdSlots[i].hpc, format: .number)
                                    TextField("Cylinders", value: $hdSlots[i].cyl, format: .number)
                                    Text("\(hdSizeMB(spt: hdSlots[i].spt, hpc: hdSlots[i].hpc, cyl: hdSlots[i].cyl)) MB")
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 60, alignment: .trailing)
                                }
                                HStack {
                                    TextField("Image file", text: $hdSlots[i].path)
                                    Button("Choose…") { chooseImage(slot: i) }
                                    Button("New…") { newImageRequest = NewImageRequest(slot: i) }
                                    Button("Eject") {
                                        // Port of hd_eject.
                                        hdSlots[i] = HDSlotState()
                                    }
                                    .disabled(hdSlots[i].path.isEmpty)
                                }
                            } else {
                                Text("Media is mounted from the menu bar (CD-ROM / Disc menu).")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }

    /// Choose an existing .img/.vhd (port of hd_file): probe the image, then
    /// confirm the geometry in a sheet before filling the slot.
    private func chooseImage(slot: Int) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["img", "vhd"]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var spt: Int32 = 0, hpc: Int32 = 0, cyl: Int32 = 0
        var isVHD: Int32 = 0, tsMismatch: Int32 = 0
        var errbuf = [CChar](repeating: 0, count: 256)
        let isMfm = pcem_bridge_hdd_is_mfm(hddController)
        let path = url.path
        let rc = path.withCString { p in
            errbuf.withUnsafeMutableBufferPointer { eb in
                pcem_bridge_hd_image_probe(p, isMfm, &spt, &hpc, &cyl,
                                           &isVHD, &tsMismatch,
                                           eb.baseAddress, Int32(eb.count))
            }
        }
        if rc == 1 {
            errorText = "Can't open file for read"
            showError = true
            return
        }
        if rc == 2 {
            errorText = String(cString: errbuf)
            showError = true
            return
        }
        let result = ProbeResult(slot: slot, path: path,
                                 spt: Int(spt), hpc: Int(hpc), cyl: Int(cyl))
        if tsMismatch != 0 {
            // wx asks YES/NO before continuing; fix, then confirm geometry.
            tsFixProbe = result
            showTsFix = true
            return
        }
        probeResult = result
    }

    private func fixTimestamp() {
        guard let probe = tsFixProbe else { return }
        if pcem_bridge_hd_vhd_fix_timestamp(probe.path) != 0 {
            errorText = "Can't fix VHD timestamps"
            showError = true
            return
        }
        probeResult = probe
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

        // HD slots from the bridge's pending snapshot.
        for i in 0..<Int(PCEM_HD_SLOTS) {
            var spt: Int32 = 0, hpc: Int32 = 0, cyl: Int32 = 0
            pcem_bridge_hd_slot_get(Int32(i), &spt, &hpc, &cyl)
            hdSlots[i] = HDSlotState(spt: Int(spt), hpc: Int(hpc), cyl: Int(cyl),
                                     path: String(cString: pcem_bridge_hd_slot_path(Int32(i))))
        }
        cdromChannel = Int(pcem_bridge_hd_cdrom_channel())
        zipChannel = Int(pcem_bridge_hd_zip_channel())
    }

    /// Push the local HD state into the bridge's pending state (the bridge
    /// dirty-checks pending vs the core globals, like wx's hd_changed).
    private func syncHD() {
        for i in 0..<Int(PCEM_HD_SLOTS) {
            pcem_bridge_hd_slot_set(Int32(i), Int32(hdSlots[i].spt),
                                    Int32(hdSlots[i].hpc), Int32(hdSlots[i].cyl),
                                    hdSlots[i].path)
        }
        pcem_bridge_hd_set_channels(Int32(cdromChannel), Int32(zipChannel))
    }

    private func applyTapped() {
        syncHD()
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
