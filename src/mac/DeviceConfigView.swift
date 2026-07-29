import SwiftUI

/// M5 slice 1: native replacement for the generic wx device-config dialog
/// (wx-deviceconfig.cc). Driven entirely by the bridge item list: a Toggle
/// per CONFIG_BINARY item, a Picker per CONFIG_SELECTION item. CONFIG_MIDI
/// items (M5 slice 3) also arrive as Pickers — the bridge synthesizes their
/// options from the CoreMIDI device list, so this view stays generic.
///
/// Like wx's OK handler, Apply dirty-checks first; when a machine is
/// running the user confirms wx's "This will reset PCem!" prompt BEFORE
/// anything is written (wx confirm() in wx-utils.cc), then the bridge
/// writes the values, saves and resets immediately — independent of the
/// parent settings sheet's Cancel.
struct DeviceConfigView: View {

    /// Which device to configure (PCEM_DEVCFG_*) plus the pending selection
    /// it resolves from (see pcem_bridge_devcfg_begin).
    let which: Int32
    let primary: Int32
    let model: Int32
    let hddInternal: String

    /// One row of the dialog, mirrored from pcem_devcfg_item_t into pure
    /// Swift (the C struct's char arrays import as tuples).
    private struct Item: Identifiable {
        let id: Int
        let description: String
        let type: Int32               // 2 = CONFIG_BINARY, 3 = CONFIG_SELECTION
        let initialValue: Int32
        var value: Int32
        var options: [(label: String, value: Int32)] = []
    }

    @State private var title = ""
    @State private var items: [Item] = []
    @State private var confirmReset = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top)
            Form {
                ForEach($items) { $item in
                    if item.type == 2 { // CONFIG_BINARY
                        Toggle(item.description, isOn: $item.value.bool)
                    } else { // CONFIG_SELECTION
                        Picker(item.description, selection: $item.value) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { _, o in
                                Text(o.label).tag(o.value)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { applyTapped() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        // Explicit height: a bare Form in a VStack collapses to zero when
        // the hosting window sizes to fit content (same gotcha as the
        // settings sheet, see PORTING_LOG 2026-07-28 Session 6).
        .frame(width: 420, height: max(180, 120 + CGFloat(items.count) * 44))
        .onAppear(perform: load)
        .alert("This will reset PCem!", isPresented: $confirmReset) {
            Button("OK") { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Okay to continue?")
        }
    }

    /// Port of the dialog's WX_INITDIALOG: snapshot every item's configured
    /// value (or its default) via the bridge.
    private func load() {
        var titleBuf = [CChar](repeating: 0, count: 256)
        let count = hddInternal.withCString { hdd in
            titleBuf.withUnsafeMutableBufferPointer { t in
                pcem_bridge_devcfg_begin(which, primary, model, hdd,
                                         t.baseAddress, Int32(t.count))
            }
        }
        guard count > 0 else { dismiss(); return }
        title = String(cString: titleBuf)

        items = (0..<count).compactMap { i in
            var raw = pcem_devcfg_item_t()
            guard pcem_bridge_devcfg_item(i, &raw) == 0 else { return nil }

            var options: [(String, Int32)] = []
            for o in 0..<raw.num_options {
                var descBuf = [CChar](repeating: 0, count: 256)
                let v = descBuf.withUnsafeMutableBufferPointer {
                    pcem_bridge_devcfg_option(i, o, $0.baseAddress, Int32($0.count))
                }
                if v != -1 {
                    options.append((String(cString: descBuf), v))
                }
            }
            // Upstream quirk: a configured value may match no option (e.g.
            // s3_bahamas64 default 4 with only 1/2 MB entries). wx shows an
            // empty combobox; we add a placeholder so the Picker stays valid.
            if raw.type == 3 && !options.contains(where: { $0.1 == raw.value }) {
                options.append((String(format: "Custom (0x%X)", raw.value), raw.value))
            }

            return Item(id: Int(i),
                        description: stringField(raw.description),
                        type: raw.type,
                        initialValue: raw.value,
                        value: raw.value,
                        options: options)
        }
    }

    /// C fixed-size char arrays import as tuples; reinterpret as a C string.
    private func stringField<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { ptr in
            String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// wx's OK handler order: dirty-check, confirm (when a machine is
    /// running), THEN write. A clean Cancel/Apply touches nothing.
    private func applyTapped() {
        guard items.contains(where: { $0.value != $0.initialValue }) else {
            dismiss()
            return
        }
        if pcem_bridge_machine_is_running() != 0 {
            confirmReset = true
        } else {
            apply()
        }
    }

    private func apply() {
        for (i, item) in items.enumerated() {
            pcem_bridge_devcfg_set(Int32(i), item.value)
        }
        pcem_bridge_devcfg_apply()
        dismiss()
    }
}

/// C Int32 values used as SwiftUI Toggle bindings (same helper as
/// SettingsView; private extensions are file-scoped).
private extension Int32 {
    var bool: Bool {
        get { self != 0 }
        set { self = newValue ? 1 : 0 }
    }
}
