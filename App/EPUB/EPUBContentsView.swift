import ReaderDomain
import SwiftUI
import UIKit

/// A reveal is explicit and bounded: one initial scroll, then at most one correction
/// when the lazy target row mounts. Scrolling/filtering/dismissal cancels ownership.
struct EPUBContentsRevealState {
    private(set) var requestID: UUID?
    private(set) var targetIndex: Int?
    private(set) var initialIssued = false

    mutating func request(_ index: Int?) {
        targetIndex = index
        requestID = index == nil ? nil : UUID()
        initialIssued = false
    }

    mutating func cancel() { request(nil) }

    mutating func initialTarget() -> Int? {
        guard requestID != nil, !initialIssued, let targetIndex else { return nil }
        initialIssued = true
        return targetIndex
    }

    mutating func mountedTarget(_ index: Int) -> Int? {
        guard requestID != nil, initialIssued, targetIndex == index else { return nil }
        cancel()
        return index
    }
}

private struct EPUBContentsRevealKey: Equatable {
    let requestID: UUID?
    let active: Bool
    let laidOut: Bool
}

private struct EPUBContentsLayoutKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Fixed, non-book diagnostics; a render snapshot never replaces the live authority check.
enum EPUBContentsAccess: String {
    case active, notPresented, sceneInactive, ownerInactive

    static func resolve(presented: Bool, sceneActive: Bool, ownerActive: Bool, liveOwnerActive: Bool) -> Self {
        guard presented else { return .notPresented }
        guard sceneActive else { return .sceneInactive }
        guard ownerActive && liveOwnerActive else { return .ownerInactive }
        return .active
    }
}

@MainActor
struct EPUBContentsView: View {
    let sessionID: UUID
    let items: [EPUBNavigationItem]
    let currentPath: String?
    let currentFragment: String?
    // Explicit value dependency makes owner changes invalidate the sheet's controls.
    let ownerActive: Bool
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    let selected: @MainActor (EPUBNavigationItem) -> Void
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var presented = false
    @State private var initializedSessionID: UUID?
    @State private var laidOut = false
    @State private var reveal = EPUBContentsRevealState()
    @FocusState private var searchFocused: Bool

    static func currentIndex(in items: [EPUBNavigationItem], path currentPath: String?, fragment currentFragment: String?) -> Int? {
        guard let currentPath else { return nil }
        if let currentFragment, !currentFragment.isEmpty,
           let exact = items.firstIndex(where: { $0.path == currentPath && $0.fragment == currentFragment }) {
            return exact
        }
        return items.firstIndex(where: { $0.path == currentPath })
    }

    /// Keep original indices (including duplicate path/fragment entries), never filtered ordinals.
    static func filteredIndices(in items: [EPUBNavigationItem], query: String) -> [Int] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return Array(items.indices) }
        return items.indices.filter { index in
            let title = items[index].title.isEmpty ? "第 \(index + 1) 节" : items[index].title
            return title.localizedStandardContains(term) || String(index + 1) == term
        }
    }

    private var access: EPUBContentsAccess {
        EPUBContentsAccess.resolve(presented: presented, sceneActive: scenePhase == .active,
                                   ownerActive: ownerActive, liveOwnerActive: isActive())
    }
    private var active: Bool { access == .active }
    private var revealKey: EPUBContentsRevealKey {
        EPUBContentsRevealKey(requestID: reveal.requestID, active: active, laidOut: laidOut)
    }

    var body: some View {
        // Resolve once for the whole render, never once per lazy row/header branch.
        let selectedIndex = Self.currentIndex(in: items, path: currentPath, fragment: currentFragment)
        let visibleIndices = Self.filteredIndices(in: items, query: query)
        VStack(spacing: 0) {
            ReaderPanelHeader(title: "目录", appearance: appearance) {
                Button { dismiss() } label: {
                    Text("完成").font(ReaderVisualStyle.panelActionFont)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(
                            minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                            minHeight: ReaderVisualStyle.minimumControlHeight
                        )
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary))
                .disabled(!active)
                .accessibilityLabel("关闭目录")
                .accessibilityFocused($closeFocused)
                .accessibilityIdentifier("reader.panel.close")
            }
            summaryHeader(currentIndex: selectedIndex)
            availabilityStatus
            searchControls(currentIndex: selectedIndex)
            ScrollViewReader { proxy in
                List {
                    if items.isEmpty {
                        emptyRow("暂无目录。")
                    } else if visibleIndices.isEmpty {
                        emptyRow("没有匹配的章节。请修改或清空筛选。")
                    } else {
                        ForEach(visibleIndices, id: \.self) { index in
                            let item = items[index]
                            let isCurrent = (selectedIndex == index)
                            Button {
                                guard active else { return }
                                reveal.cancel()
                                selected(item)
                            } label: {
                                ReaderDirectoryChapterRow(
                                    title: item.title.isEmpty ? "第 \(index + 1) 节" : item.title,
                                    ordinal: index + 1,
                                    totalCount: items.count,
                                    isCurrent: isCurrent,
                                    appearance: appearance
                                )
                                .padding(.leading, CGFloat(min(max(item.depth, 0), 4)) * 12)
                            }
                            .id(index)
                            .accessibilityIdentifier("reader.chapter.\(index)")
                            .accessibilityValue(isCurrent ? "当前章节" : "")
                            .accessibilityHint("阅读本章")
                            .buttonStyle(.plain)
                            .disabled(!active)
                            .listRowBackground(isCurrent ? appearance.selection : appearance.surface)
                            .listRowSeparator(.hidden)
                            .task(id: reveal.initialIssued ? revealKey : nil) {
                                // Unlike another timed retry, this only runs after the target exists.
                                guard reveal.targetIndex == index, reveal.initialIssued else { return }
                                let owner = reveal.requestID
                                await Task.yield()
                                guard !Task.isCancelled, active, reveal.requestID == owner,
                                      let target = reveal.mountedTarget(index) else { return }
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    Section {
                        Text("当前支持 EPUB 目录与章节/锚点跳转；EPUB 书签暂未纳入本批范围。")
                            .font(.caption)
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("epub.directory.scopeNote")
                    }
                    .listRowBackground(appearance.surface)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(appearance.surface)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: EPUBContentsLayoutKey.self,
                            value: geometry.size.width > 0 && geometry.size.height > 0)
                    }
                }
                .onPreferenceChange(EPUBContentsLayoutKey.self) { [laidOut = $laidOut] ready in
                    laidOut.wrappedValue = ready
                }
                .simultaneousGesture(DragGesture().onChanged { _ in reveal.cancel() })
                .task(id: revealKey) {
                    let owner = reveal.requestID
                    guard active, laidOut, owner != nil else { return }
                    // Wait for the List transaction, not an arbitrary fixed sleep.
                    await Task.yield()
                    guard !Task.isCancelled, active, laidOut, reveal.requestID == owner,
                          let target = reveal.initialTarget() else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .onAppear {
            presented = true
            initializeSession(currentIndex: selectedIndex)
        }
        .onChange(of: active) { available in
            if available { initializeSession(currentIndex: selectedIndex) }
            else { reveal.cancel(); searchFocused = false }
        }
        .onDisappear {
            presented = false
            laidOut = false
            reveal.cancel()
            closeFocused = false
            searchFocused = false
        }
        .task(id: active) {
            guard active, UIAccessibility.isVoiceOverRunning else { return }
            await Task.yield()
            if !Task.isCancelled, active { closeFocused = true }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private func initializeSession(currentIndex: Int?) {
        guard active, initializedSessionID != sessionID else { return }
        initializedSessionID = sessionID
        query = ""
        reveal.request(currentIndex)
    }

    private var availabilityStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(active ? "目录可操作" : "目录暂不可操作。返回前台后可关闭目录并重新打开。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .accessibilityIdentifier("epub.directory.availability")
                .accessibilityValue("state=\(access.rawValue);presented=\(presented);scene=\(scenePhase == .active);owner=\(ownerActive);live=\(isActive())")
            if !active {
                Button("关闭目录后重开") {
                    reveal.cancel()
                    searchFocused = false
                    // Closing is not a grant: the parent rechecks canInteract + session ID.
                    // In background or after replacement this remains a safe no-op.
                    close()
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
                .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
                .accessibilityIdentifier("epub.directory.recover")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .padding(.vertical, 4)
        .background(appearance.surface)
    }

    private func dismiss() {
        guard active else { return }
        reveal.cancel()
        presented = false
        searchFocused = false
        close()
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(appearance.secondary)
            .listRowBackground(appearance.surface)
    }

    private func searchControls(currentIndex: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("筛选标题或章节序号", text: Binding(
                    get: { query },
                    set: {
                        guard active else { return }
                        query = $0
                        reveal.cancel()
                    }
                ))
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("epub.directory.search")
                if !query.isEmpty {
                    Button {
                        guard active else { return }
                        query = ""
                        reveal.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary))
                    .accessibilityLabel("清空筛选")
                    .accessibilityIdentifier("epub.directory.clear")
                }
            }
            .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
            Button {
                guard active else { return }
                query = ""
                searchFocused = false
                reveal.request(currentIndex)
            } label: {
                Label(query.isEmpty ? "定位当前章节" : "清空筛选并定位当前章节", systemImage: "location")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
            .disabled(currentIndex == nil)
            .accessibilityHint(query.isEmpty ? "滚动目录至当前章节，不切换正文" : "先清空筛选，再滚动目录至当前章节，不切换正文")
            .accessibilityIdentifier("epub.directory.current")
        }
        .foregroundStyle(appearance.foreground)
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .background(appearance.surface)
        .disabled(!active)
    }

    private func summaryHeader(currentIndex: Int?) -> some View {
        VStack(spacing: 8) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    totalCountBadge
                    summaryDetailText(currentIndex: currentIndex)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        totalCountBadge
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 12)
                        summaryDetailText(currentIndex: currentIndex)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        totalCountBadge
                        summaryDetailText(currentIndex: currentIndex)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Rectangle()
                .fill(appearance.edge)
                .frame(height: ReaderVisualStyle.panelDividerHeight)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .padding(.top, 8)
        .background(appearance.surface)
    }

    private var totalCountBadge: some View {
        Text("共 \(items.count) 章")
            .font(.system(.subheadline, design: .serif).weight(.medium).monospacedDigit())
            .foregroundStyle(appearance.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("总章节数，共 \(items.count) 章")
            .accessibilityIdentifier("reader.directory.total")
    }

    private func summaryDetailText(currentIndex: Int?) -> some View {
        let text: String
        if let currentIndex {
            text = "当前第 \(currentIndex + 1) 章 · 共 \(items.count) 章"
        } else if !items.isEmpty {
            text = "未找到当前章节 · 共 \(items.count) 章"
        } else {
            text = "暂无章节"
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(appearance.foreground.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }
}
