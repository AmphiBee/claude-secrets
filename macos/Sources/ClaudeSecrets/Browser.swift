import SwiftUI
import SecretsCore

/// Fenêtre principale : barre latérale (collections et services) + détail, comme Mail ou Notes.
struct ContentView: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                Status(symbol: "hourglass", text: "Ouverture du coffre…",
                       detail: "La première lecture du trousseau peut prendre quelques secondes.")
            case .failed(let msg):
                VStack(spacing: 12) {
                    Status(symbol: "lock.slash", text: "Le coffre reste fermé.", detail: msg)
                    Button("Réessayer") { model.load(force: true) }
                }
            case .ready:
                Browser(model: model)
            }
        }
        .background(Theme.paper)
        .tint(Theme.copper)
        .overlay(alignment: .bottom) { ToastView(model: model) }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .onAppear { model.load(); model.replayEntrance() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newSecret: SecretSheet(model: model, editing: nil)
            case .edit(let e): SecretSheet(model: model, editing: e)
            case .importEnv: ImportSheet(model: model)
            case .group(let e): GroupSheet(model: model, entry: e)
            case .bwSetup: BwSetupSheet(model: model)
            case .bwUnlock: BwUnlockSheet(model: model)
            case .awsImport: AwsImportSheet(model: model)
            }
        }
        .confirmationDialog("Supprimer ce profil AWS ?", isPresented: Binding(
            get: { model.confirmAWS != nil }, set: { if !$0 { model.confirmAWS = nil } }), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { if let e = model.confirmAWS { model.delete(e) } }
            Button("Annuler", role: .cancel) { model.confirmAWS = nil }
        } message: {
            Text("Les clés seront retirées du trousseau. Pense à retirer aussi la ligne credential_process de ~/.aws/config.")
        }
    }
}

struct ToastView: View {
    @ObservedObject var model: VaultModel
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 14) {
                Text(t.text).font(.callout)
                if let label = t.actionLabel, let key = t.actionKey {
                    Button(label) { model.undo(key) }.buttonStyle(.plain).fontWeight(.bold)
                        .underline().foregroundStyle(Theme.toastAccent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.ink).foregroundStyle(Theme.paper)
            .padding(.bottom, 16).transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}

struct Browser: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailView(model: model)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Chercher un secret, un identifiant, un service")
        .onSubmit(of: .search) { model.copyFirst() }
        .onChange(of: model.query) { model.rebuild() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.syncNow() } label: {
                    if model.syncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .help("Synchroniser Bitwarden (⌘R)").accessibilityLabel("Synchroniser Bitwarden").disabled(model.syncing)
                Button { model.sheet = .newSecret } label: { Label("Nouveau", systemImage: "plus") }
                    .help("Nouveau secret (⌘N)")
            }
        }
    }
}

// MARK: - Barre latérale

struct Sidebar: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        List(selection: Binding<String?>(get: { model.selection }, set: { if let s = $0 { model.select(s) } })) {
            SwiftUI.Section {
                ForEach(model.collections) { SideRow(item: $0).tag($0.id) }
            }
            ForEach(model.sidebar, id: \.letter) { group in
                SwiftUI.Section {
                    ForEach(group.items) { SideRow(item: $0).tag($0.id) }
                } header: {
                    Text(group.letter).font(Theme.title(12)).foregroundStyle(Theme.copper)
                }
            }
            if !model.buckets.isEmpty {
                SwiftUI.Section("Autres") {
                    ForEach(model.buckets) { SideRow(item: $0).tag($0.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Seal(size: 24)
                Text("Claude Secrets").font(Theme.title(15)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
        }
    }
}

struct SideRow: View {
    let item: SideItem
    var body: some View {
        HStack(spacing: 8) {
            if let s = item.symbol {
                Image(systemName: s).frame(width: 20).foregroundStyle(Theme.copper)
            } else {
                Monogram(label: item.label, size: 20)
            }
            Text(item.label).lineLimit(1)
            if let t = item.tag { Stamp(text: t, small: true) }
            Spacer(minLength: 4)
            Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Détail

struct DetailView: View {
    @ObservedObject var model: VaultModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let d = model.detail
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let m = d.monogram { Monogram(label: m, size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text(d.title).font(Theme.title(28)).foregroundStyle(Theme.ink).lineLimit(1)
                        if let t = d.tag { Stamp(text: t) }
                    }
                    Text(d.subtitle).font(.callout).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 14)
            Rectangle().fill(Theme.rule).frame(height: 1)
            if d.count == 0 {
                Status(symbol: "tray", text: model.isSearching ? "Rien ne correspond." : "Rien ici.", detail: nil)
            } else {
                List(selection: $model.selectedEntry) {
                    ForEach(d.sections) { sec in
                        SwiftUI.Section {
                            ForEach(Array(sec.members.enumerated()), id: \.element.base) { i, e in
                                EntryRow(model: model, entry: e).tag(e.base)
                                    .opacity(model.entered || reduceMotion ? 1 : 0)
                                    .offset(y: model.entered || reduceMotion ? 0 : 6)
                                    .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.5)
                                        .delay(Double(min(i, 14)) * 0.03), value: model.entered)
                            }
                        } header: {
                            if !sec.label.isEmpty {
                                HStack(spacing: 8) {
                                    Monogram(label: sec.label, size: 20)
                                    Text(sec.label).font(Theme.title(15)).foregroundStyle(Theme.ink)
                                    if let t = sec.tag { Stamp(text: t, small: true) }
                                    Spacer()
                                }
                                .padding(.vertical, 5).padding(.horizontal, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.paper)
                            }
                        }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .onKeyPress(.return) { model.copyFirst(); return .handled }
            }
        }
        .background(Theme.paper)
    }
}
