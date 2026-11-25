import SwiftUI
import ReaderDomain
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var model: LibraryViewModel
    @StateObject private var readerRoutes = BookReadingRouteOwner()
    @State private var plannedNavigation = LibraryPlannedNavigation()
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.defaultAppearance.rawValue
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @State private var selectedSection: LibrarySection = .shelf
    @State private var shelfQuery = LibraryShelfQuery()
    @State private var drawerPresented = false
    @State private var informationRoute: LibraryInformationRoute?
    @State private var displayedInformation: LibraryInformationPage = .diagnostics
    @Environment(\.colorScheme) private var colorScheme
    @AccessibilityFocusState private var focusedLibraryControl: String?

    private var appAppearance: AppAppearance { AppAppearance.restored(from: appAppearanceRawValue) }
    private var appearance: LibraryAppearance {
        LibraryAppearance(colorScheme: colorScheme, appAppearance: appAppearance)
    }
    /// New static destinations must not compete with import or reading presentation.
    private var canOpenPlannedFeatures: Bool {
        model.service != nil && model.canPresentLibraryFeedback && !model.importing && !model.deletingBook
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
        if EPUBUITestFixture.isRequested {
            return try await EPUBUITestFixture.makeService()
        }
        if ReadingUITestFixture.isRequested {
            return try await ReadingUITestFixture.makeService()
        }
        #endif
        return try await LibraryService.openDefault()
    }

    var body: some View {
        NavigationStack {
            LibraryNavigationShell(section: sectionSelection, drawerPresented: drawerPresentation,
                canNavigate: canNavigateManagement, appearance: appearance, focusedControl: $focusedLibraryControl,
                shelf: shelfContent,
                explore: LibraryExploreContent(appearance: appearance, canOpenFeatures: canChangeManagement,
                                               onOpenFeature: openPlannedFeature),
                settings: LibrarySettingsContent(appearance: appearance, options: managementOptions()))
            .navigationTitle(selectedSection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                if selectedSection == .shelf {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { model.beginFileSelection() } label: {
                            Label("导入", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                                .font(AppVisualStyle.actionFont.weight(.semibold))
                                .imageScale(.medium)
                                .foregroundStyle(appearance.accent)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(AppControlButtonStyle(
                            foreground: appearance.accent,
                            surface: appearance.accentSoft,
                            border: appearance.accent.opacity(0.28),
                            cornerRadius: 22
                        ))
                        .accessibilityLabel("导入书籍")
                        .disabled(!model.canBeginFileSelection || !canChangeManagement)
                        .accessibilityHidden(drawerPresented)
                        .accessibilityHint("支持导入 TXT 与本地非 DRM 可重排 EPUB")
                    }
                }
            }
            .navigationDestination(isPresented: plannedFeaturePresentation) {
                switch plannedNavigation.displayedFeature {
                case .aiStory:
                    StoryLaunchView(
                        model: model,
                        appearance: appearance,
                        isRouteActive: plannedNavigation.activeRoute?.feature == .aiStory
                    )
                default:
                    LibraryPlannedFeatureView(feature: plannedNavigation.displayedFeature, appearance: appearance)
                }
            }
            .navigationDestination(isPresented: informationPresentation) {
                switch displayedInformation {
                case .diagnostics:
                    if developerMode {
                        ReaderDiagnosticsView(importState: model.importDiagnostics,
                                              importSummary: model.processingSummary, libraryAppearance: appearance)
                    }
                case .license:
                    LibraryLicenseView(appearance: appearance)
                }
            }
        }
        .overlay(alignment: .leading) {
            LibrarySidebarView(section: selectedSection, presented: drawerPresentation,
                canNavigate: canNavigateManagement, appearance: appearance,
                onSection: selectDrawerSection,
                focusedControl: $focusedLibraryControl)
        }
        .onChange(of: developerMode) { enabled in
            if !enabled, informationRoute?.page == .diagnostics { informationRoute = nil }
        }
        .onChange(of: drawerPresented) { open in
            focusedLibraryControl = open ? "library.close" : "library.menu"
        }
        .accessibilityIdentifier("library.screen")
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if ReadingUITestFixture.isRequested || EPUBUITestFixture.isRequested { ReadingUITestSchemeProbe() }
            #endif
        }
        .fullScreenCover(item: readerPresentation) { route in
            Group {
                switch route.content {
                case .txt(let txtRoute):
                    ReaderScreen(model: txtRoute.model, routeID: txtRoute.id) { readerRoutes.finishExit(txtRoute.id) }
                case .epub(let epubModel):
                    EPUBReaderScreen(model: epubModel, routeID: route.id) { readerRoutes.finishExit(route.id) }
                }
            }
            .id(route.id)
            .environment(\.readingTimeBook, route.bookID)
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
            EncodingChoiceView(
                choice: choice,
                appearance: appearance,
                select: { model.choose($0, for: choice) },
                cancel: { Task { await model.cancelImport() } }
            )
            .interactiveDismissDisabled()
        }
        .alert("书架提示", isPresented: Binding(
            get: { model.canPresentLibraryFeedback && model.message != nil },
            set: { if !$0 && model.canPresentLibraryFeedback { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var shelfContent: some View {
        LibraryShelfContent(
            books: model.books,
            notice: model.notice,
            importing: model.importing,
            importPresentation: model.importPresentation,
            serviceUnavailable: model.service == nil,
            appearance: appearance,
            coverLoader: model.coverLoader,
            canImport: model.canBeginFileSelection && canChangeManagement,
            query: $shelfQuery,
            canManageBooks: canChangeManagement,
            onDeleteBook: { book in
                guard selectedSection == .shelf, canChangeManagement else { return }
                model.deleteBook(book)
            },
            onOpenBook: { book in
                guard canChangeManagement else { return }
                if let service = model.service { readerRoutes.open(book: book, service: service) }
            },
            onDismissNotice: { model.notice = nil },
            onCancelImport: { Task { await model.cancelImport() } },
            onRetry: { Task { await model.start() } },
            onImport: { model.beginFileSelection() }
        )
    }

    private func managementOptions() -> some View {
        LibraryManagementOptions(appearance: appearance, appAppearance: appAppearance,
            developerMode: $developerMode, canChange: canChangeManagement, onAppearance: chooseAppearance,
            onOpenFeature: openPlannedFeature, onInformation: openInformation)
    }

    private func chooseAppearance(_ option: AppAppearance) {
        guard canChangeManagement else { return }
        appAppearanceRawValue = option.rawValue
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
                guard canChangeManagement else { return }
            }
            drawerPresented = open
        })
    }

    private func selectDrawerSection(_ section: LibrarySection) {
        guard drawerPresented, canNavigateManagement else { return }
        selectedSection = section
        drawerPresented = false
    }

    private func openInformation(_ page: LibraryInformationPage) {
        guard canChangeManagement, page != .diagnostics || developerMode else { return }
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

    private var readerPresentation: Binding<BookReadingRoute?> {
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
