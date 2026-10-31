import SwiftUI
import ReaderDomain
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var model: LibraryViewModel
    @StateObject private var readerRoutes = ReaderRouteOwner()
    @State private var plannedNavigation = LibraryPlannedNavigation()
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.defaultAppearance.rawValue
    @AppStorage(LibraryLayout.storageKey) private var libraryLayoutRawValue = LibraryLayout.defaultLayout.rawValue
    @State private var selectedSection: LibrarySection = .shelf
    @State private var drawerPresented = false
    @State private var informationRoute: LibraryInformationRoute?
    @State private var displayedInformation: LibraryInformationPage = .diagnostics
    @Environment(\.colorScheme) private var colorScheme

    private var appAppearance: AppAppearance { AppAppearance.restored(from: appAppearanceRawValue) }
    private var layout: LibraryLayout { LibraryLayout.restored(from: libraryLayoutRawValue) }
    private var appearance: LibraryAppearance {
        LibraryAppearance(colorScheme: colorScheme, appAppearance: appAppearance)
    }
    /// New static destinations must not compete with import or reading presentation.
    private var canOpenPlannedFeatures: Bool {
        model.service != nil && model.canPresentLibraryFeedback && !model.importing
            && model.encodingChoice?.id == nil && model.message == nil
            && readerRoutes.presentation?.id == nil
    }
    // A dismissed picker session is retained by the existing model; its dismissal gate above is authoritative.
    private var canNavigateManagement: Bool {
        canOpenPlannedFeatures && !plannedNavigation.isActive && informationRoute == nil
    }
    private var canChangeManagement: Bool { canNavigateManagement && !drawerPresented }

    init() {
        _model = StateObject(wrappedValue: LibraryViewModel(makeService: Self.makeLibraryService))
    }

    private static func makeLibraryService() async throws -> LibraryService {
        #if DEBUG
        if ReadingUITestFixture.isRequested {
            return try await ReadingUITestFixture.makeService()
        }
        #endif
        return try await LibraryService.openDefault()
    }

    var body: some View {
        NavigationStack {
            LibraryNavigationShell(layout: layout, section: sectionSelection, drawerPresented: drawerPresentation,
                canNavigate: canNavigateManagement, appearance: appearance,
                onDrawerSection: selectDrawerSection, onDrawerInformation: openDrawerInformation,
                shelf: shelfContent,
                explore: LibraryExploreContent(appearance: appearance, canOpenFeatures: canChangeManagement,
                                               onOpenFeature: openPlannedFeature),
                settings: LibrarySettingsContent(appearance: appearance, options: managementOptions(asMenu: false)))
            .navigationTitle(layout == .direct ? "阅境" : selectedSection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                if layout == .direct {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu { managementOptions(asMenu: true) } label: {
                            Label("更多", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                                .font(AppVisualStyle.actionFont).imageScale(.medium)
                                .foregroundStyle(appearance.foreground)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 12))
                        .disabled(!canChangeManagement)
                    }
                }
                if layout == .direct || selectedSection == .shelf {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { model.beginFileSelection() } label: {
                            Label("导入", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                                .font(AppVisualStyle.actionFont).imageScale(.medium)
                                .foregroundStyle(appearance.accent)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(AppControlButtonStyle(foreground: appearance.accent, surface: appearance.accent.opacity(0.12)))
                        .accessibilityLabel("导入书籍")
                        .disabled(!model.canBeginFileSelection || !canChangeManagement)
                        .accessibilityHidden(drawerPresented)
                        .accessibilityHint("当前仅支持 TXT；EPUB 规划中，未接入")
                    }
                }
            }
            .navigationDestination(isPresented: plannedFeaturePresentation) {
                LibraryPlannedFeatureView(feature: plannedNavigation.displayedFeature, appearance: appearance)
            }
            .navigationDestination(isPresented: informationPresentation) {
                switch displayedInformation {
                case .diagnostics:
                    ReaderDiagnosticsView(importState: model.importDiagnostics, importSummary: model.processingSummary)
                case .license:
                    LibraryLicenseView(appearance: appearance)
                }
            }
        }
        .accessibilityIdentifier("library.screen")
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if ReadingUITestFixture.isRequested { ReadingUITestSchemeProbe() }
            #endif
        }
        .fullScreenCover(item: readerPresentation) { route in
            ReaderScreen(model: route.model, routeID: route.id, layout: layout) { readerRoutes.finishExit(route.id) }
                .id(route.id)
        }
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseProcessingCache() }
        }
        .onChange(of: readerRoutes.presentation?.id) { id in
            if id == nil { Task { await model.reload() } }
        }
        .background {
            if let session = model.fileSelection {
                DocumentPickerBridge.Presentation(session: session, onDismiss: model.documentPickerDismissed).id(session.id)
            }
        }
        .sheet(item: $model.encodingChoice) { choice in
            EncodingChoiceView(choice: choice, select: { model.choose($0, for: choice) },
                cancel: { Task { await model.cancelImport() } }).interactiveDismissDisabled()
        }
        .alert("书架提示", isPresented: Binding(
            get: { model.canPresentLibraryFeedback && model.message != nil },
            set: { if !$0 && model.canPresentLibraryFeedback { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var shelfContent: some View {
        LibraryShelfContent(books: model.books, notice: model.notice, importing: model.importing,
            importPresentation: model.importPresentation, serviceUnavailable: model.service == nil,
            layout: layout, appearance: appearance, canOpenFeatures: canChangeManagement,
            onOpenBook: { book in
                guard canChangeManagement else { return }
                if let service = model.service { readerRoutes.open(bookID: book.id, service: service) }
            },
            onDismissNotice: { model.notice = nil },
            onCancelImport: { Task { await model.cancelImport() } },
            onRetry: { Task { await model.start() } }, onOpenFeature: openPlannedFeature)
    }

    private func managementOptions(asMenu: Bool) -> some View {
        LibraryManagementOptions(asMenu: asMenu, appearance: appearance, appAppearance: appAppearance,
            layout: layout, canChange: canChangeManagement, onAppearance: chooseAppearance,
            onLayout: chooseLayout, onOpenFeature: openPlannedFeature, onInformation: openInformation)
    }

    private func chooseAppearance(_ option: AppAppearance) {
        guard canChangeManagement else { return }
        appAppearanceRawValue = option.rawValue
    }

    private func chooseLayout(_ option: LibraryLayout) {
        guard canChangeManagement else { return }
        libraryLayoutRawValue = option.rawValue
        selectedSection = .shelf
        drawerPresented = false
    }

    private var sectionSelection: Binding<LibrarySection> {
        Binding(get: { selectedSection }, set: { value in
            guard canChangeManagement else { return }
            selectedSection = value
        })
    }

    private var drawerPresentation: Binding<Bool> {
        Binding(get: { drawerPresented }, set: { open in
            if open {
                guard layout == .sidebar, canChangeManagement else { return }
            }
            drawerPresented = open
        })
    }

    private func selectDrawerSection(_ section: LibrarySection) {
        guard drawerPresented, canNavigateManagement else { return }
        selectedSection = section
        drawerPresented = false
    }

    private func openDrawerInformation(_ page: LibraryInformationPage) {
        guard drawerPresented, canNavigateManagement else { return }
        drawerPresented = false
        openInformation(page)
    }

    private func openInformation(_ page: LibraryInformationPage) {
        guard canChangeManagement else { return }
        displayedInformation = page
        informationRoute = LibraryInformationRoute(page: page)
    }

    private var informationPresentation: Binding<Bool> {
        let expectedID = informationRoute?.id
        return Binding(get: { informationRoute != nil }, set: { presented in
            guard !presented, let expectedID, informationRoute?.id == expectedID else { return }
            informationRoute = nil
        })
    }

    private var readerPresentation: Binding<ReaderPresentation?> {
        let expected = readerRoutes.presentation
        return Binding(get: { readerRoutes.presentation }, set: { value in
            guard value == nil, let expected else { return }
            readerRoutes.presentationEnded(expected)
        })
    }

    private func openPlannedFeature(_ feature: LibraryPlannedFeature) {
        guard canChangeManagement else { return }
        _ = plannedNavigation.begin(feature, allowed: canOpenPlannedFeatures)
    }

    private var plannedFeaturePresentation: Binding<Bool> {
        let expectedID = plannedNavigation.activeRoute?.id
        return Binding(get: { plannedNavigation.isActive }, set: { isPresented in
            guard !isPresented, let expectedID else { return }
            _ = plannedNavigation.end(id: expectedID)
        })
    }
}
