import SwiftUI
import AppKit

/// M4 step 3: sheets for the Hard Discs tab of the settings dialog.
///
/// `NewHardDiscSheet` ports the wx "HdNewDlg" (hdnew_dlgproc in wx-config.c):
/// destination, format (raw .img / fixed / dynamic / differencing VHD),
/// block size, the 46-entry BIOS type table, and the SPT/HPC/CYL ↔ size MB ↔
/// type cross-updates. `ConfirmGeometrySheet` ports "HdSizeDlg"
/// (hdsize_dlgproc): confirm/adjust the probed geometry of an existing image.
/// Image I/O lives in the bridge (pcem_bridge_hd_image_create/_probe).

// MARK: - Shared helpers

struct HDTypeEntry {
    let cylinders: Int
    let heads: Int
    var sizeMB: Int { cylinders * heads * 17 * 512 / 1_048_576 }
    var label: String {
        String(format: "Type %02d : cylinders=%d, heads=%d, size=%dMB",
               0, cylinders, heads, sizeMB) // index patched in hdTypeOptions()
    }
}

/// The 46-entry AT BIOS drive-type table from the bridge (wx hd_types).
func hdTypeTable() -> [HDTypeEntry] {
    (0..<Int(pcem_bridge_hd_type_count())).map { i in
        var c: Int32 = 0, h: Int32 = 0
        pcem_bridge_hd_type_get(Int32(i), &c, &h)
        return HDTypeEntry(cylinders: Int(c), heads: Int(h))
    }
}

/// Index 0 = "Custom type", 1...46 = table entries (wx combo numbering).
func hdTypeIndex(spt: Int, hpc: Int, cyl: Int, table: [HDTypeEntry]) -> Int {
    guard spt == 17 else { return 0 }
    for (i, t) in table.enumerated() where t.heads == hpc && t.cylinders == cyl {
        return i + 1
    }
    return 0
}

/// The wx size formula: tracks * heads * sectors * 512 bytes, shown in MB.
func hdSizeMB(spt: Int, hpc: Int, cyl: Int) -> Int {
    cyl * hpc * spt * 512 / 1_048_576
}

// MARK: - New image sheet (port of HdNewDlg)

struct NewHardDiscSheet: View {
    /// Called on success with (path, spt, hpc, cyl) to fill the slot.
    var onFill: (String, Int, Int, Int) -> Void

    @State private var path = ""
    @State private var format = 0          // 0 raw, 1 fixed, 2 dynamic, 3 diff
    @State private var blockLarge = true   // 2 MB vs 512 KB (dynamic/diff)
    @State private var spt = 63
    @State private var hpc = 16
    @State private var cyl = 511
    @State private var parentPath = ""
    @State private var table = hdTypeTable()

    @State private var isCreating = false
    @State private var progress: Double = 0
    @State private var showError = false
    @State private var errorText = ""
    @State private var showCreatedInfo = false
    @State private var pendingFill: (String, Int, Int, Int)?
    @Environment(\.dismiss) private var dismiss

    private let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField("File", text: $path)
                    Button("Browse…") { browseDestination() }
                }
                Picker("Format", selection: $format) {
                    Text("Raw (.img)").tag(0)
                    Text("Fixed-size VHD (.vhd)").tag(1)
                    Text("Dynamic-size VHD (.vhd)").tag(2)
                    Text("Differencing VHD (.vhd)").tag(3)
                }
                if format >= 2 {
                    Picker("Block size", selection: $blockLarge) {
                        Text("Large blocks (2 MB)").tag(true)
                        Text("Small blocks (512 KB)").tag(false)
                    }
                }
                if format == 3 {
                    // Differencing VHD: geometry comes from the parent.
                    HStack {
                        TextField("Parent VHD", text: $parentPath)
                        Button("Browse…") { browseParent() }
                    }
                } else {
                    Picker("Type", selection: typeBinding) {
                        Text("Custom type").tag(0)
                        ForEach(Array(table.enumerated()), id: \.offset) { i, t in
                            Text(String(format: "Type %02d : cylinders=%d, heads=%d, size=%dMB",
                                        i + 1, t.cylinders, t.heads, t.sizeMB)).tag(i + 1)
                        }
                    }
                    HStack {
                        TextField("Sectors", value: $spt, format: .number)
                        TextField("Heads", value: $hpc, format: .number)
                        TextField("Cylinders", value: $cyl, format: .number)
                    }
                    HStack {
                        TextField("Size (MB)", value: sizeBinding, format: .number)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            if isCreating {
                ProgressView(value: progress, total: 100) {
                    Text("Creating drive, please wait...")
                }
                .padding([.leading, .trailing])
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") { createTapped() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
            .padding()
        }
        .frame(width: 480, height: format == 3 ? 260 : 340)
        .onReceive(progressTimer) { _ in
            guard isCreating else { return }
            let p = pcem_bridge_hd_create_progress()
            if p >= 0 { progress = Double(p) }
        }
        .alert("PCem error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
        .alert("PCem", isPresented: $showCreatedInfo) {
            Button("OK") {
                if let fill = pendingFill { onFill(fill.0, fill.1, fill.2, fill.3) }
                dismiss()
            }
        } message: {
            Text(format == 3
                 ? "Differencing VHD image created.\n\nWARNING: Do not open or modify the parent image(s) while this file exists."
                 : "Drive created, remember to partition and format the new drive.")
        }
    }

    // MARK: Cross-updates (ports of the IDC_EDIT1-4 / IDC_HDTYPE handlers)
    //
    // Size and type are COMPUTED bindings over the geometry, not stored
    // state: wx updates the other fields programmatically (which doesn't
    // re-fire its edit handlers), and this is the SwiftUI equivalent —
    // a stored size + onChange both ways feeds back on itself and decays
    // the geometry to 0 (bug found 2026-07-28).

    /// Picker binding: read = table entry matching the current geometry
    /// (0 = Custom); write = apply the entry's cylinders/heads + 17 spt.
    private var typeBinding: Binding<Int> {
        Binding(
            get: { hdTypeIndex(spt: spt, hpc: hpc, cyl: cyl, table: table) },
            set: { idx in
                guard idx > 0 else { return } // picking "Custom" does nothing (wx)
                let t = table[idx - 1]
                cyl = t.cylinders
                hpc = t.heads
                spt = 17
            })
    }

    /// Size field binding: read = MB from the geometry; write = the wx
    /// IDC_EDIT4 rule (63 spt / 16 heads, cylinders from the MB value).
    private var sizeBinding: Binding<Int> {
        Binding(
            get: { hdSizeMB(spt: spt, hpc: hpc, cyl: cyl) },
            set: { mb in
                spt = 63
                hpc = 16
                cyl = mb * 1_048_576 / (16 * 63 * 512)
            })
    }

    // MARK: Panels

    private func browseDestination() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = [format == 0 ? "img" : "vhd"]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "harddisk.\(format == 0 ? "img" : "vhd")"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func browseParent() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["vhd"]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            parentPath = url.path
        }
    }

    // MARK: Create (port of the hdnew_dlgproc OK handler)

    private func createTapped() {
        // Same validation messages as wx.
        if path.isEmpty {
            errorText = "Please enter a valid filename"
            showError = true
            return
        }
        if format != 3 {
            if spt > 63 {
                errorText = "Drive has too many sectors (maximum is 63)"
                showError = true
                return
            }
            if hpc > 16 {
                errorText = "Drive has too many heads (maximum is 16)"
                showError = true
                return
            }
            if cyl > Int(PCEM_HD_MAX_CYLINDERS) {
                errorText = "Drive has too many cylinders (maximum is \(PCEM_HD_MAX_CYLINDERS))"
                showError = true
                return
            }
        } else if parentPath.isEmpty {
            errorText = "Please select the parent VHD"
            showError = true
            return
        }

        isCreating = true
        progress = 0
        let path = self.path, parent = self.parentPath
        let spt32 = Int32(spt), hpc32 = Int32(hpc), cyl32 = Int32(cyl)
        let format32 = Int32(format), block32: Int32 = blockLarge ? 1 : 0
        DispatchQueue.global(qos: .userInitiated).async {
            var os: Int32 = 0, oh: Int32 = 0, oc: Int32 = 0
            let rc = pcem_bridge_hd_image_create(path, spt32, hpc32, cyl32,
                                                 format32, block32,
                                                 parent.isEmpty ? nil : parent,
                                                 &os, &oh, &oc)
            DispatchQueue.main.async {
                isCreating = false
                if rc == 0 {
                    pendingFill = (path, Int(os), Int(oh), Int(oc))
                    showCreatedInfo = true
                } else {
                    errorText = rc == 1 ? "Can't open file for write" : "Can't create VHD"
                    showError = true
                }
            }
        }
    }
}

// MARK: - Confirm geometry sheet (port of HdSizeDlg)

struct ConfirmGeometrySheet: View {
    let path: String
    let initialSpt: Int
    let initialHpc: Int
    let initialCyl: Int
    /// Called on OK with (path, spt, hpc, cyl) to fill the slot.
    var onFill: (String, Int, Int, Int) -> Void

    @State private var spt = 0
    @State private var hpc = 0
    @State private var cyl = 0
    @State private var table = hdTypeTable()
    @State private var showError = false
    @State private var errorText = ""
    @Environment(\.dismiss) private var dismiss

    /// Same computed-binding trick as NewHardDiscSheet: read = matching
    /// table entry (0 = Custom), write = apply the entry's geometry.
    private var typeBinding: Binding<Int> {
        Binding(
            get: { hdTypeIndex(spt: spt, hpc: hpc, cyl: cyl, table: table) },
            set: { idx in
                guard idx > 0 else { return }
                let t = table[idx - 1]
                cyl = t.cylinders
                hpc = t.heads
                spt = 17
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Text(path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Picker("Type", selection: typeBinding) {
                    Text("Custom type").tag(0)
                    ForEach(Array(table.enumerated()), id: \.offset) { i, t in
                        Text(String(format: "Type %02d : cylinders=%d, heads=%d, size=%dMB",
                                    i + 1, t.cylinders, t.heads, t.sizeMB)).tag(i + 1)
                    }
                }
                HStack {
                    TextField("Sectors", value: $spt, format: .number)
                    TextField("Heads", value: $hpc, format: .number)
                    TextField("Cylinders", value: $cyl, format: .number)
                }
                Text("\(hdSizeMB(spt: spt, hpc: hpc, cyl: cyl)) MB")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { okTapped() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 280)
        .onAppear {
            spt = initialSpt
            hpc = initialHpc
            cyl = initialCyl
        }
        .alert("PCem error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
    }

    private func okTapped() {
        // Same validation as hdsize_dlgproc's OK handler.
        if spt > 63 {
            errorText = "Drive has too many sectors (maximum is 63)"
        } else if hpc > 16 {
            errorText = "Drive has too many heads (maximum is 16)"
        } else if cyl > Int(PCEM_HD_MAX_CYLINDERS) {
            errorText = "Drive has too many cylinders (maximum is \(PCEM_HD_MAX_CYLINDERS))"
        } else {
            onFill(path, spt, hpc, cyl)
            dismiss()
            return
        }
        showError = true
    }
}
