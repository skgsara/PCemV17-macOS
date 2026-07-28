import SwiftUI

/// M4 step 1: native replacement for the wx machine-manager dialog
/// (src/wx-config_sel.c). Lists the *.cfg files in configs/ and offers
/// New / Copy / Rename / Delete / Boot, all through the C bridge
/// (pcem_bridge_config_*). The per-machine settings dialog is M4 step 2.
struct MachineManagerView: View {

    /// Kind of name-entry alert: New needs no source, Copy/Rename act on the
    /// selected machine. Mirrors the IDC_NEW / IDC_COPY / IDC_RENAME handlers.
    private enum NameAction {
        case new, copy(String), rename(String)

        var title: String {
            switch self {
            case .new: return "New Machine"
            case .copy: return "Copy Machine"
            case .rename: return "Rename Machine"
            }
        }
    }

    /// Boot: dismiss the sheet, release the mouse, switch the core to this
    /// config. Configure: open the settings editor for this config WITHOUT
    /// booting it (only while no machine is running). Done: just dismiss.
    /// Provided by the presenter (AppDelegate).
    var onBoot: (String) -> Void
    var onConfigure: (String) -> Void
    var onDone: () -> Void

    @State private var machines: [String] = []
    @State private var selection: String?
    @State private var currentName = ""
    @State private var running = false

    @State private var nameAction: NameAction?
    @State private var enteredName = ""
    @State private var errorMessage: String?
    @State private var deleteCandidate: String?

    var body: some View {
        VStack(spacing: 12) {
            List(selection: $selection) {
                ForEach(machines, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        if name == currentName && running {
                            Text("running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(name)
                    .onTapGesture(count: 2) { onBoot(name) }
                }
            }
            .frame(minWidth: 560, minHeight: 240)

            HStack {
                Button("New…") { beginNameEntry(.new) }
                Button("Copy…") {
                    if let selection { beginNameEntry(.copy(selection)) }
                }
                .disabled(selection == nil)
                Button("Rename…") {
                    if let selection { beginNameEntry(.rename(selection)) }
                }
                .disabled(selection == nil)
                Button("Delete…") { deleteCandidate = selection }
                    .disabled(selection == nil)
                // Configure edits a config WITHOUT booting it — only safe
                // while no machine is running (the wx machine manager flow).
                // For the running machine use Machine → Settings… instead.
                Button("Configure…") {
                    if let selection { onConfigure(selection) }
                }
                .disabled(selection == nil || running)

                Spacer()

                Button("Boot") { if let selection { onBoot(selection) } }
                    .disabled(selection == nil)
                    .keyboardShortcut(.defaultAction)
                Button("Done") { onDone() }
            }

            Text("New machines start as a copy of the current settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear(perform: reload)
        .alert(nameAction?.title ?? "", isPresented: nameEntryPresented) {
            TextField("Name", text: $enteredName)
            Button("OK") { submitName() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("PCem", isPresented: errorPresented, presenting: errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Delete “\(deleteCandidate ?? "")”?",
               isPresented: deletePresented) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the configuration file. It cannot be undone.")
        }
    }

    // MARK: - Alert presentation bindings (nil-state <-> Bool)

    private var nameEntryPresented: Binding<Bool> {
        Binding(get: { nameAction != nil },
                set: { if !$0 { nameAction = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } })
    }

    // MARK: - Bridge access

    private func reload() {
        pcem_bridge_config_rescan()
        var names: [String] = []
        for i in 0..<pcem_bridge_config_count() {
            if let cName = pcem_bridge_config_name(i) {
                names.append(String(cString: cName))
            }
        }
        machines = names
        running = pcem_bridge_machine_is_running() != 0
        currentName = pcem_bridge_current_config_name()
            .map { String(cString: $0) } ?? ""
        if let selection, !names.contains(selection) {
            self.selection = nil
        }
        // Launcher state: preselect the remembered (last-booted) machine.
        if selection == nil {
            let remembered = String(cString: pcem_bridge_remembered_config_name())
            if names.contains(remembered) {
                selection = remembered
            } else if running, names.contains(currentName) {
                selection = currentName
            }
        }
    }

    private func beginNameEntry(_ action: NameAction) {
        enteredName = ""
        nameAction = action
    }

    /// Maps the bridge's return code to either a list reload or an error
    /// message (the wx dialog shows "Already exists" and asks again; we show
    /// the same message and keep the alert's text for another try).
    private func submitName() {
        guard let action = nameAction else { return }
        let name = enteredName
        let result: Int32
        switch action {
        case .new:
            result = pcem_bridge_config_create(name)
        case .copy(let source):
            result = pcem_bridge_config_copy(source, name)
        case .rename(let source):
            result = pcem_bridge_config_rename(source, name)
        }
        switch result {
        case 0:
            reload()
            selection = name
        case 1:
            errorMessage = "A configuration with that name already exists."
        case 2:
            errorMessage = "That name cannot be used."
        default:
            errorMessage = "The file operation failed."
        }
    }

    private func performDelete() {
        guard let name = deleteCandidate else { return }
        if pcem_bridge_config_delete(name) != 0 {
            errorMessage = "The file operation failed."
        }
        reload()
    }
}
