import SwiftUI

struct SourceSidebar: View {
    private struct FolderRequest: Identifiable {
        let id = UUID()
        var folder: SourceFolder?
        var initialMember: SourceFolderMember?
    }

    @ObservedObject var store: TrafficStore
    @EnvironmentObject var appState: AppState
    @FocusState private var searchFocused: Bool
    @State private var search = ""
    @State private var folderRequest: FolderRequest?
    @State private var folderError: String?

    @State private var appsExpanded = true
    @State private var domainsExpanded = false
    @State private var expandedApps: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    favoritesSection
                    sectionTitle("所有").padding(.top, 2)
                    appsSection
                    domainsSection
                    if !store.sourceFolders.isEmpty { foldersSection.padding(.top, 5) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 1)
            }
            sidebarFooter
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
        .background(ProxymanTheme.sidebarBackground.ignoresSafeArea(edges: .top))
        .onReceive(NotificationCenter.default.publisher(for: .focusSourceFilter)) { _ in
            searchFocused = true
        }
        .contextMenu {
            Button("清空已固定") { appState.pinnedDomains.removeAll() }
        }
        .sheet(item: $folderRequest) { request in
            SourceFolderEditor(store: store, folder: request.folder, initialMember: request.initialMember)
        }
        .alert("来源文件夹", isPresented: Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } }
        )) {
            Button("好") { folderError = nil }
        } message: {
            Text(folderError ?? "")
        }
    }

    private var foldersSection: some View {
        let counts = store.sourceFolderCounts
        return Group {
            sectionTitle("来源文件夹")
            ForEach(store.sourceFolders.filter { folder in
                matchesSearch(folder.name) || folder.members.contains { matchesSearch($0.name) }
            }) { folder in
                sourceButton(.folder(folder.id)) {
                    sourceSymbol("folder.fill", tint: .blue)
                    Text(folder.name).lineLimit(1)
                    countBadge(counts[folder.id, default: 0])
                }
                .contextMenu {
                    Button("编辑文件夹…") { folderRequest = FolderRequest(folder: folder) }
                    Button("删除文件夹", role: .destructive) {
                        do { try store.removeSourceFolder(folder.id) }
                        catch { folderError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func folderMembership(_ member: SourceFolderMember) -> some View {
        Menu("来源文件夹") {
            ForEach(store.sourceFolders) { folder in
                let contained = folder.members.contains(member.normalized)
                Button(contained ? "从 \(folder.name) 移出" : "加入 \(folder.name)") {
                    do { try store.toggleSourceFolderMembership(member, folderID: folder.id) }
                    catch { folderError = error.localizedDescription }
                }
            }
            if !store.sourceFolders.isEmpty { Divider() }
            Button("新建文件夹…") { folderRequest = FolderRequest(initialMember: member) }
        }
    }

    private var favoritesSection: some View {
        Group {
            sectionTitle("收藏夹")
            sourceButton(.pinned) {
                sourceSymbol("pin.fill", tint: .blue)
                Text("已固定")
                countBadge(appState.pinnedDomains.count)
            }
            sourceButton(.saved) {
                sourceSymbol("tray.and.arrow.down.fill", tint: .blue)
                Text("Saved")
                countBadge(store.saved.count)
            }
            if let archiveName = store.archiveName {
                sourceButton(.archive) {
                    sourceSymbol("doc")
                    Text(archiveName).lineLimit(1)
                    countBadge(store.archive.count)
                }
            }
        }
    }

    private var appsSection: some View {
        let apps = store.clientApps
        let showChildren = appsExpanded || !search.isEmpty
        let domainsByApp = appDomains()
        return Group {
            sourceGroup("应用程序", icon: "folder.fill", count: apps.count, expanded: $appsExpanded)
            if showChildren {
                ForEach(apps, id: \.name) { app in
                    let domains = domainsByApp[app.name] ?? []
                    if matchesSearch(app.name) || !domains.isEmpty {
                        let expanded = search.isEmpty ? expandedApps.contains(app.name) : !domains.isEmpty
                        HStack(spacing: 0) {
                            disclosureButton(app.name, expanded: expanded) {
                                if !expandedApps.insert(app.name).inserted { expandedApps.remove(app.name) }
                            }
                            sourceButton(.client(app.name), indent: 0) {
                                ClientIconView(image: app.icon)
                                Text(app.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .help("\(app.name) · \(app.count) 条请求")
                        }
                        .padding(.leading, 25)
                        .background(store.filterMode == .client(app.name) ? ProxymanTheme.sidebarSelection : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contextMenu { folderMembership(.client(app.name)) }
                        ForEach(domains, id: \.self) { host in
                            domainRow(host, mode: .clientDomain(client: app.name, host: host), indent: 65)
                        }
                    }
                }
            }
        }
    }

    private var domainsSection: some View {
        let domains = store.domainSummary
        return Group {
            sourceGroup("域名", icon: "globe", count: domains.count, expanded: $domainsExpanded)
            if domainsExpanded || !search.isEmpty {
                ForEach(domains.filter { matchesSearch($0.host) }) { item in
                    domainRow(item.host, mode: .domain(item.host), indent: 45)
                        .help("\(item.host) · \(item.count) 条请求")
                }
            }
        }
    }

    private func appDomains() -> [String: [String]] {
        guard (appsExpanded && !expandedApps.isEmpty) || !search.isEmpty else { return [:] }
        let domains = store.domainsByClient
        if search.isEmpty { return domains.filter { expandedApps.contains($0.key) } }
        return domains.mapValues { $0.filter(matchesSearch) }
    }

    private func domainRow(_ host: String, mode: TrafficFilterMode, indent: CGFloat) -> some View {
        sourceButton(mode, indent: indent) {
            sourceSymbol("globe", tint: .blue)
            Text(host).lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(host)
        .contextMenu {
            folderMembership(.domain(host))
            Button(appState.pinnedDomains.contains(host) ? "取消固定" : "固定到收藏夹") {
                if appState.pinnedDomains.contains(host) {
                    appState.pinnedDomains.removeAll { $0 == host }
                } else {
                    appState.pinnedDomains.append(host)
                }
            }
        }
    }

    private func sourceGroup(_ title: String, icon: String, count: Int, expanded: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            disclosureButton(title, expanded: expanded.wrappedValue) { expanded.wrappedValue.toggle() }
            sourceButton(.all, indent: 0) {
                sourceSymbol(icon, tint: .blue)
                Text(title)
                countBadge(count, showZero: true)
            }
        }
        .padding(.leading, 7)
    }

    private func disclosureButton(_ title: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: ProxymanTheme.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((expanded ? "折叠" : "展开") + title)
    }

    private func sourceButton<Label: View>(_ mode: TrafficFilterMode, indent: CGFloat = 25,
                                          @ViewBuilder label: () -> Label) -> some View {
        Button {
            store.filterMode = mode
        } label: {
            HStack(spacing: 7, content: label)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, indent)
                .padding(.trailing, 11)
                .frame(height: ProxymanTheme.rowHeight)
                .contentShape(Rectangle())
                .background(mode != .all && store.filterMode == mode ? ProxymanTheme.sidebarSelection : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .frame(height: 23)
    }

    private func sourceSymbol(_ name: String, tint: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(width: 15)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func countBadge(_ count: Int, showZero: Bool = false) -> some View {
        Spacer(minLength: 5)
        if count > 0 || showZero {
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(Color.primary.opacity(0.10), in: Capsule())
        }
    }

    private func matchesSearch(_ value: String) -> Bool {
        search.isEmpty || value.localizedCaseInsensitiveContains(search)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 7) {
            Menu {
                Button("新建来源文件夹…") { folderRequest = FolderRequest() }
                Button("全部流量") { store.filterMode = .all; search = "" }
                Button("生成示例流量") { appState.store.addSampleData() }
            } label: {
                Image(systemName: "plus").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("添加来源")
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("筛选 (⇧⌘F)", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { search = "" }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.10)) }
        }
        .padding(.horizontal, 8)
        .frame(height: ProxymanTheme.bottomBarHeight)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
    }
}
