import SwiftUI
import HerdrKit

/// Start an agent (or shell): pick program, where, optional first task.
struct NewAgentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialSpace: String?
    var onCreated: (String) -> Void

    @State private var program = "claude"
    @State private var target: Target = .newFolder
    @State private var folder = ""
    @State private var task = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showAllPrograms = false
    @FocusState private var focus: Field?

    enum Target: Hashable { case space(String), newFolder }
    enum Field { case folder, task }

    private static let featured = ["claude", "codex", "shell"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(title: "Program")
                    programGrid
                    SectionLabel(title: "Where")
                    whereSection
                    if program != "shell" {
                        SectionLabel(title: "Task (optional)")
                        TextField("What should it work on?", text: $task, axis: .vertical)
                            .font(HF.ui(15.5))
                            .lineLimit(3...8)
                            .focused($focus, equals: .task)
                            .padding(14)
                            .herdrCard()
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(HF.ui(13.5)).foregroundStyle(HC.blocked)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(HC.canvas)
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Once Start is pressed the box is already starting it: no take-backs.
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Start", systemImage: "arrow.up") { start() }
                            .buttonStyle(.glassProminent)
                            .disabled(!canStart)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(busy)
        .presentationDragIndicator(.visible)
        .onAppear {
            if let s = initialSpace ?? store.selectedSpaceID, store.spaces.contains(where: { $0.id == s }) { target = .space(s) }
            else if let s = store.spaces.first { target = .space(s.id) }
        }
    }

    private var canStart: Bool {
        if busy || store.phase != .connected { return false }
        if case .newFolder = target { return !folder.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    // MARK: Program grid

    private var programs: [ProgramInfo] {
        var list = Self.featured.compactMap { ProgramCatalog.info($0) }
        if showAllPrograms {
            list += ProgramCatalog.launchable.filter { !Self.featured.contains($0.key) }
        }
        return list
    }

    private var programGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(programs, id: \.key) { p in
                    let sel = p.key == program
                    Button { program = p.key } label: {
                        VStack(spacing: 8) {
                            ProgramIcon(program: p.key, size: 26)
                            Text(p.key == "shell" ? "Shell" : p.name)
                                .font(HF.ui(13.5, .medium)).foregroundStyle(HC.fg).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .background(sel ? HC.selected : HC.background, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(sel ? HC.accent : HC.border, lineWidth: sel ? 1.5 : 1))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
            if !showAllPrograms {
                Button { withAnimation(.smooth) { showAllPrograms = true } } label: {
                    Label("More agents", systemImage: "chevron.down").font(HF.ui(13.5, .medium))
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Where

    private var whereSection: some View {
        VStack(spacing: 0) {
            ForEach(store.spaces) { s in
                let name = store.spaceName(s)
                Button { target = .space(s.id) } label: {
                    HStack(spacing: 12) {
                        SpaceBadge(name: name.isEmpty ? "~" : name, colorKey: SpaceBadge.colorKey(for: s.id))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name.isEmpty ? "~" : name).font(HF.ui(15.5, .medium)).foregroundStyle(HC.fg)
                            let path = store.tildePath(s.folder)
                            if path != (name.isEmpty ? "~" : name) {
                                Text(path).font(HF.ui(12.5)).foregroundStyle(HC.dim).lineLimit(1)
                            }
                        }
                        Spacer()
                        if target == .space(s.id) {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(HC.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Rectangle().fill(HC.border).frame(height: HM.hairline).padding(.leading, 48)
            }
            Button { target = .newFolder; focus = .folder } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 15)).foregroundStyle(HC.muted).frame(width: 22)
                    Text("New space in a folder").font(HF.ui(15.5, .medium)).foregroundStyle(HC.fg)
                    Spacer()
                    if target == .newFolder {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(HC.accent)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if target == .newFolder {
                TextField("~/projects/my-app", text: $folder)
                    .font(HF.mono(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .folder)
                    .padding(12)
                    .background(HC.canvas, in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .herdrCard()
    }

    // MARK: Start

    private func start() {
        let argv = ProgramCatalog.info(program)?.run
        let taskText = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let t: String? = program == "shell" || taskText.isEmpty ? nil : taskText
        busy = true
        error = nil
        Task {
            do {
                let addr: String
                switch target {
                case .space(let id):
                    addr = try await store.newTab(inSpace: id, argv: argv, task: t, name: nil)
                case .newFolder:
                    addr = try await store.newSpace(folder: expand(folder), argv: argv, task: t)
                }
                busy = false
                dismiss()
                if !addr.isEmpty { onCreated(addr) }
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    private func expand(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p == "~" { return store.home }
        if p.hasPrefix("~/") { return store.home + p.dropFirst(1) }
        if !p.hasPrefix("/") { return store.home + "/" + p }
        return p
    }
}
