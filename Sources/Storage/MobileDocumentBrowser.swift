#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Observation
import OSLog

@MainActor @Observable
final class MobileDocumentCommands {
    var addRequest = 0
    var searchText = ""
    func addPayment() { addRequest += 1 }
}

struct MobileDocumentsView: View {
    @State private var requestedURL: URL?

    var body: some View {
        MobileDocumentBrowser(requestedURL: $requestedURL)
            .ignoresSafeArea()
            .onOpenURL { requestedURL = $0 }
    }
}

private struct MobileDocumentBrowser: UIViewControllerRepresentable {
    @Binding var requestedURL: URL?

    final class Coordinator { var consumedURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> TallyDocumentBrowserController {
        TallyDocumentBrowserController()
    }

    func updateUIViewController(_ controller: TallyDocumentBrowserController, context: Context) {
        guard let url = requestedURL else {
            context.coordinator.consumedURL = nil
            return
        }
        guard context.coordinator.consumedURL != url else { return }
        context.coordinator.consumedURL = url
        controller.requestExternalFile(url)
        Task { @MainActor in
            if requestedURL == url { requestedURL = nil }
        }
    }
}

@MainActor
final class TallyDocumentBrowserController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    private var stagingDirectories: Set<URL> = []
    private var openingFile = false
    private var pendingOpenRequest: MobileOpenRequestOrder.Ticket?
    private var externalRevealSources: Set<URL> = []
    private var didApplyLaunchPreference = false
    private var receivedDirectOpenRequest = false
    private var openRequestOrder = MobileOpenRequestOrder()
    private var launchTask: Task<Void, Never>?
    private var launchCover: UIView?
    private var launchAccessibilityElements: [Any]?
    private var didFinishLaunchPresentation = false
    private let lastFileStore = MobileLastUsedFileStore(defaults: MobileLaunchEnvironment.defaults)
    nonisolated private static let fileQueue = DispatchQueue(label: "com.asherbloom.Tally.mobile-last-file", qos: .utility)
    private var lastRecordedURL: URL?
    nonisolated private static let logger = Logger(subsystem: "com.asherbloom.Tally", category: "MobileLaunch")
    private weak var activeEditor: MobileDocumentEditorController?
    private lazy var optionsButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), style: .plain,
                                     target: self, action: #selector(presentBrowserOptions))
        button.accessibilityIdentifier = "tallyOptionsButton"
        button.accessibilityLabel = "Tally options"
        return button
    }()
    #if DEBUG
    private var testFixture: MobileDocumentTestSupport?
    #endif

    init() {
        super.init(forOpening: [.tallyDocument])
        delegate = self
        allowsDocumentCreation = true
        allowsPickingMultipleItems = false
        localizedCreateDocumentActionTitle = "New Tally File"
        additionalLeadingNavigationBarButtonItems = [optionsButton]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard MobileLaunchEnvironment.isEnabled, !didFinishLaunchPresentation else { return }
        let behavior = TallyLaunchBehavior(rawValue: MobileLaunchEnvironment.defaults.string(forKey: TallyLaunchBehavior.preferenceKey) ?? "") ?? .lastUsedFile
        guard behavior == .lastUsedFile else { return }
        // The browser must appear before it can present an editor. Cover that
        // first appearance while resolving and opening the previous file.
        let cover = UIView(frame: view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .systemBackground
        cover.isAccessibilityElement = true
        cover.accessibilityLabel = "Opening Tally"
        cover.accessibilityIdentifier = "tallyLaunchCover"
        cover.accessibilityViewIsModal = true
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: cover.centerYAnchor)
        ])
        indicator.startAnimating()
        launchAccessibilityElements = view.accessibilityElements
        view.addSubview(cover)
        // The system browser publishes accessibility through its hosted view.
        // Explicitly expose only the loading screen until launch is settled.
        view.accessibilityElements = [cover]
        launchCover = cover
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // UIDocumentBrowser hosts a system view service, which can add its
        // browser content after our initial view has loaded.
        if let launchCover {
            view.bringSubviewToFront(launchCover)
            view.accessibilityElements = [launchCover]
        }
    }

    private func finishLaunchPresentation() {
        // A scene URL can finish or fail before UIKit loads this view. Once
        // launch is settled, loading the browser must not install a new cover.
        didFinishLaunchPresentation = true
        if launchCover != nil {
            view.accessibilityElements = launchAccessibilityElements
            launchAccessibilityElements = nil
        }
        launchCover?.removeFromSuperview()
        launchCover = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        if MobileDocumentTestSupport.isEnabled && testFixture == nil {
            do {
                let fixture = try MobileDocumentTestSupport()
                testFixture = fixture
                let reopen = UIBarButtonItem(title: "Reopen Fixture", primaryAction: UIAction { [weak self] _ in self?.openFile(fixture.url) })
                reopen.accessibilityIdentifier = "nativeMobileReopen"
                additionalTrailingNavigationBarButtonItems = [reopen]
                openFile(fixture.url)
            } catch {
                showError("Test Fixture Failed", message: error.localizedDescription)
            }
        }
        if MobileLaunchTestSupport.isEnabled, !didApplyLaunchPreference,
           let url = MobileLaunchTestSupport.explicitRequestedURL {
            requestExternalFile(url)
        }
        #endif
        applyLaunchPreferenceIfNeeded()
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { openFile(url) }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        cancelLaunchRestoration()
        Task { [self] in
            if CloudDocuments.shared.documentsURL == nil { await CloudDocuments.shared.prepare() }
            if let directory = CloudDocuments.shared.documentsURL {
                do {
                    let url = try Self.createNewFile(in: directory, ledger: Ledger())
                    importHandler(nil, .none)
                    let revealedURL = try await revealDocument(at: url, importIfNeeded: false)
                    openFile(revealedURL)
                } catch {
                    importHandler(nil, .none)
                    showError("Couldn’t Create File", message: error.localizedDescription)
                }
            } else {
                // The browser moves this owned staging file to the location the
                // person selected. A staged file is never opened as their file.
                do {
                    let directory = try Self.makeStagingDirectory(purpose: "Creation")
                    stagingDirectories.insert(directory)
                    let url = directory.appendingPathComponent("Cash Flow.tally")
                    try LedgerCodec.encode(Ledger()).write(to: url, options: .atomic)
                    importHandler(url, .move)
                } catch {
                    importHandler(nil, .none)
                    showError("Couldn’t Create File", message: error.localizedDescription)
                }
            }
        }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
        cleanStaging(sourceURL.deletingLastPathComponent())
        // The asynchronous URL-open path owns these imports and their original
        // request order. A delegate callback must not turn one into a new intent.
        guard !externalRevealSources.contains(sourceURL) else { return }
        openFile(destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: (any Error)?) {
        cleanStaging(documentURL.deletingLastPathComponent())
        guard !externalRevealSources.contains(documentURL) else { return }
        showError("Couldn’t Create File", message: error?.localizedDescription ?? "Choose another location and try again.")
    }

    /// Explicit Files/URL opens take priority over any cold-launch restoration.
    func requestExternalFile(_ url: URL) {
        cancelLaunchRestoration(preservingLaunchCover: true)
        let request = openRequestOrder.request(url)
        externalRevealSources.insert(url)
        Task { [weak self] in
            guard let self else { return }
            do {
                let revealedURL = try await revealDocument(at: url, importIfNeeded: true)
                #if DEBUG
                try MobileLaunchTestSupport.recordImport(sourceURL: url, destinationURL: revealedURL)
                #endif
                guard openRequestOrder.isCurrent(request) else { return }
                performOpen(.init(url: revealedURL, generation: request.generation))
            } catch {
                guard openRequestOrder.isCurrent(request) else { return }
                finishLaunchPresentation()
                showError("Couldn’t Open File", message: error.localizedDescription)
            }
        }
    }

    func cancelLaunchRestoration(preservingLaunchCover: Bool = false) {
        receivedDirectOpenRequest = true
        didApplyLaunchPreference = true
        launchTask?.cancel()
        openRequestOrder.invalidate()
        if !preservingLaunchCover { finishLaunchPresentation() }
    }

    @objc private func presentBrowserOptions() {
        cancelLaunchRestoration()
        guard presentedViewController == nil else { return }
        // The system file browser forwards bar-button actions across its view
        // service, but not a custom UIMenu. Present these choices in UIKit.
        let choices = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        choices.addAction(UIAlertAction(title: "Settings", style: .default) { [weak self, weak choices] _ in
            choices?.dismiss(animated: true) { [weak self] in self?.presentTallySettings() }
        })
        choices.addAction(UIAlertAction(title: "Privacy & Support", style: .default) { [weak self, weak choices] _ in
            choices?.dismiss(animated: true) { [weak self] in self?.presentPrivacySupport() }
        })
        #if DEBUG
        if MobileLaunchTestSupport.isEnabled,
           ProcessInfo.processInfo.environment["TALLY_MOBILE_LAUNCH_TEST_HIDE_FIXTURE_ACTIONS"] != "1" {
            for (name, url) in [("A", MobileLaunchTestSupport.fixtureAURL), ("B", MobileLaunchTestSupport.fixtureBURL)] {
                guard let url else { continue }
                choices.addAction(UIAlertAction(title: "Open fixture \(name)", style: .default) { [weak self, weak choices] _ in
                    choices?.dismiss(animated: true) { [weak self] in self?.openFile(url) }
                })
            }
        }
        #endif
        choices.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        choices.popoverPresentationController?.sourceItem = optionsButton
        present(choices, animated: true)
    }

    private func applyLaunchPreferenceIfNeeded() {
        guard !didApplyLaunchPreference else { return }
        didApplyLaunchPreference = true
        guard MobileLaunchEnvironment.isEnabled else {
            finishLaunchPresentation()
            return
        }
        let behavior = TallyLaunchBehavior(rawValue: MobileLaunchEnvironment.defaults.string(forKey: TallyLaunchBehavior.preferenceKey) ?? "") ?? .lastUsedFile
        guard behavior == .lastUsedFile else {
            finishLaunchPresentation()
            return
        }
        launchTask = Task { [weak self] in
            guard let self else { return }
            // Allow an explicit scene URL delivered during launch to claim it.
            await Task.yield()
            #if DEBUG
            if MobileLaunchTestSupport.isEnabled { launchCover?.accessibilityValue = "resolving" }
            await MobileLaunchTestSupport.delayRestorationIfRequested()
            #endif
            guard !Task.isCancelled, !receivedDirectOpenRequest else { return }
            let access = await resolveLastFile()
            guard !Task.isCancelled, !receivedDirectOpenRequest,
                  activeEditor == nil, !openingFile else {
                access?.stopAccessing()
                return
            }
            guard let access else {
                finishLaunchPresentation()
                return
            }
            performOpen(openRequestOrder.request(access.url), restoring: true, restoredAccess: access)
        }
    }

    private func resolveLastFile() async -> MobileLastUsedFileStore.ResolvedFile? {
        let store = lastFileStore
        return await withCheckedContinuation { continuation in
            Self.fileQueue.async {
                do { continuation.resume(returning: try store.resolve()) }
                catch {
                    Self.logger.notice("Could not restore the previous file: \(error.localizedDescription, privacy: .private)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func rememberFile(_ url: URL, force: Bool = false) {
        guard MobileLaunchEnvironment.isEnabled, force || lastRecordedURL != url else { return }
        lastRecordedURL = url
        let store = lastFileStore
        Self.fileQueue.async { [weak self] in
            do { try store.remember(url) }
            catch {
                Self.logger.notice("Could not remember a file: \(error.localizedDescription, privacy: .private)")
                Task { @MainActor [weak self] in
                    if self?.lastRecordedURL == url { self?.lastRecordedURL = nil }
                }
            }
        }
    }

    func openFile(_ url: URL) {
        cancelLaunchRestoration()
        performOpen(openRequestOrder.request(url))
    }

    private func performOpen(_ request: MobileOpenRequestOrder.Ticket, restoring: Bool = false,
                             restoredAccess: MobileLastUsedFileStore.ResolvedFile? = nil) {
        guard openRequestOrder.isCurrent(request) else {
            restoredAccess?.stopAccessing()
            return
        }
        guard !openingFile else {
            if !restoring { pendingOpenRequest = request }
            restoredAccess?.stopAccessing()
            return
        }
        let url = request.url
        if let activeEditor {
            restoredAccess?.stopAccessing()
            guard activeEditor.fileURL != url else { return }
            activeEditor.onSwitchFile?(request)
            return
        }
        openingFile = true
        let access = MobileDocumentAccess(url: url)
        let document = MobileTallyDocument(opening: url)
        Task { [self] in
            let opened = await document.open()
            #if DEBUG
            if opened, launchCover != nil, MobileLaunchTestSupport.isEnabled {
                launchCover?.accessibilityValue = "presenting"
                await MobileLaunchTestSupport.delayEditorPresentationIfRequested()
            }
            #endif
            if !openRequestOrder.isCurrent(request) {
                if opened { _ = await document.closeFile() }
                openingFile = false
                restoredAccess?.stopAccessing()
                openPendingRequest()
                return
            }
            guard opened else {
                openingFile = false
                restoredAccess?.stopAccessing()
                finishLaunchPresentation()
                if !restoring {
                    showError("Couldn’t Open File", message: "The file couldn’t be opened. Check that it is available and try again.")
                }
                return
            }
            openingFile = false
            let editor = MobileDocumentEditorController(document: document)
            editor.fileAccess = access
            editor.restoredAccess = restoredAccess
            editor.onLocationChange = { [weak self] in self?.rememberFile($0) }
            editor.onSceneActivated = { [weak self] in self?.rememberFile($0, force: true) }
            editor.onRename = { [weak self] url, name in
                guard let self else { throw CancellationError() }
                return try await renameDocument(at: url, proposedName: name)
            }
            if view.window?.windowScene?.activationState == .foregroundActive {
                rememberFile(document.fileURL)
            }
            #if DEBUG
            if let testFixture, testFixture.url == url { editor.testFixture = testFixture }
            #endif
            let finishEditing: (MobileOpenRequestOrder.Ticket?, Bool) -> Void = { [weak self, weak editor] nextRequest, closeWindow in
                guard let self, !openingFile else { return }
                openingFile = true
                Task { [self] in
                    guard await document.closeFile() else {
                        openingFile = false
                        pendingOpenRequest = nil
                        editor?.showError("Couldn’t Close File", message: "Your latest changes couldn’t be saved. Try again.")
                        return
                    }
                    editor?.restoredAccess?.stopAccessing()
                    editor?.restoredAccess = nil
                    editor?.fileAccess = nil
                    if closeWindow, let session = editor?.view.window?.windowScene?.session {
                        activeEditor = nil
                        openingFile = false
                        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { [weak self] _ in
                            self?.dismiss(animated: true)
                        }
                        return
                    }
                    dismiss(animated: true) { [weak self] in
                        guard let self else { return }
                        activeEditor = nil
                        openingFile = false
                        if let pending = pendingOpenRequest, openRequestOrder.isCurrent(pending) {
                            openPendingRequest()
                        } else if let nextRequest, openRequestOrder.isCurrent(nextRequest) {
                            performOpen(nextRequest)
                        } else {
                            #if DEBUG
                            if document.isRemoved || MobileDocumentTestSupport.isFileActionsEnabled { testFixture?.cleanup() }
                            #endif
                        }
                    }
                }
            }
            editor.onClose = { [weak self] recoveredURL, closeWindow in
                guard let self else { return }
                cancelLaunchRestoration()
                let next = recoveredURL.map { openRequestOrder.request($0) }
                finishEditing(next, closeWindow)
            }
            editor.onSwitchFile = { finishEditing($0, false) }
            let navigation = UINavigationController(rootViewController: editor)
            activeEditor = editor
            navigation.modalPresentationStyle = .fullScreen
            navigation.isModalInPresentation = true
            // A cold launch replaces the neutral cover directly. File choices
            // made from the visible browser retain their normal transition.
            let animatePresentation = !restoring && launchCover == nil
            let presentEditor: () -> Void = { [weak self] in
                guard let self else { return }
                present(navigation, animated: animatePresentation) { [weak self] in
                    guard let self, openRequestOrder.isCurrent(request) else { return }
                    finishLaunchPresentation()
                }
            }
            if presentedViewController != nil {
                dismiss(animated: false, completion: presentEditor)
            } else {
                presentEditor()
            }
            document.startWatching()
        }
    }

    private func openPendingRequest() {
        guard let pending = pendingOpenRequest else { return }
        pendingOpenRequest = nil
        guard openRequestOrder.isCurrent(pending) else { return }
        performOpen(pending)
    }

    private func cleanStaging(_ directory: URL) {
        guard stagingDirectories.remove(directory) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    isolated deinit {
        launchTask?.cancel()
        for directory in stagingDirectories { try? FileManager.default.removeItem(at: directory) }
    }

    static func makeStagingDirectory(purpose: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Tally\(purpose)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func createNewFile(in directory: URL, ledger: Ledger) throws -> URL {
        let contents = try LedgerCodec.encode(ledger)
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " \(index)"
            let candidate = directory.appendingPathComponent("Cash Flow\(suffix).tally")
            do {
                try contents.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                index += 1
            }
        }
    }
}

@MainActor
private final class MobileDocumentEditorController: UIViewController, UIDocumentPickerDelegate, UISearchResultsUpdating {
    private let tallyDocument: MobileTallyDocument
    private let commands = MobileDocumentCommands()
    private lazy var addButton = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in
        self?.commands.addPayment()
    })
    private lazy var renameAction = UIAction(title: "Rename", image: UIImage(systemName: "pencil"), identifier: UIAction.Identifier("tallyRenameFile")) { [weak self] _ in
        self?.presentRename()
    }
    private lazy var shareAction = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up"), identifier: UIAction.Identifier("tallyShareFile")) { [weak self] _ in
        self?.shareFile()
    }
    private lazy var optionsButton = makeTallyOptionsButton(fileActions: [renameAction, shareAction])
    private lazy var searchController: UISearchController = {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search income and expenses"
        return search
    }()
    private var content: UIHostingController<AnyView>?
    private var deletionAlert: UIAlertController?
    private var recoveryPicker: UIDocumentPickerViewController?
    private var recoveryDirectory: URL?
    private var activationObserver: NSObjectProtocol?
    private var sceneActivationObserver: NSObjectProtocol?
    private var renameAlert: UIAlertController?
    private var isRenaming = false
    var onClose: ((URL?, Bool) -> Void)?
    var onSwitchFile: ((MobileOpenRequestOrder.Ticket) -> Void)?
    var onLocationChange: ((URL) -> Void)?
    var onSceneActivated: ((URL) -> Void)?
    var onRename: ((URL, String) async throws -> URL)?
    var fileAccess: MobileDocumentAccess?
    var restoredAccess: MobileLastUsedFileStore.ResolvedFile?
    var fileURL: URL { tallyDocument.fileURL }
    #if DEBUG
    private var fixtureButtons: [UIBarButtonItem] = []
    var testFixture: MobileDocumentTestSupport? {
        didSet {
            fixtureButtons = testFixture?.buttons() ?? []
            updateNavigation()
        }
    }
    #endif

    init(document: MobileTallyDocument) {
        tallyDocument = document
        super.init(nibName: nil, bundle: nil)
        document.onAvailabilityChange = { [weak self] in self?.refreshAvailability() }
        let activated: @MainActor @Sendable () -> Void = { [weak self] in self?.tallyDocument.checkAfterActivation() }
        activationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in activated() }
        }
        sceneActivationObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
            let scene = notification.object as? UIWindowScene
            Task { @MainActor [weak self, weak scene] in
                guard let self, let scene, viewIfLoaded?.window?.windowScene === scene,
                      !tallyDocument.isRemoved else { return }
                onSceneActivated?(fileURL)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        definesPresentationContext = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigationItem.searchController = searchController
            navigationItem.preferredSearchBarPlacement = .integrated
        }
        updateNavigation()
        configureContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshAvailability()
    }

    private func updateNavigation() {
        navigationItem.title = fileURL.deletingPathExtension().lastPathComponent
        navigationItem.style = .editor
        // File actions belong to the More menu. Supplying any of these native
        // document hooks would turn the filename back into a preview button.
        navigationItem.renameDelegate = nil
        navigationItem.documentProperties = nil
        navigationItem.titleMenuProvider = nil
        renameAction.attributes = tallyDocument.isRemoved || tallyDocument.editingDisabled || isRenaming ? [.disabled] : []
        shareAction.attributes = tallyDocument.isRemoved || isRenaming ? [.disabled] : []
        if !tallyDocument.isRemoved, viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive {
            onLocationChange?(fileURL)
        }
        // UIKit supplies the native chevron; the browser owns its presentation.
        navigationItem.backAction = UIAction(title: "Files", image: UIImage(systemName: "chevron.backward")) { [weak self] _ in
            self?.onClose?(nil, false)
        }
        addButton.accessibilityIdentifier = "addExpenseButton"
        addButton.accessibilityLabel = "Add income or expense"
        addButton.isEnabled = !tallyDocument.isRemoved && !tallyDocument.editingDisabled
            && tallyDocument.model.ledger.expenses.count < LedgerCodec.maximumExpenseCount
        navigationItem.rightBarButtonItems = [optionsButton, addButton]
        #if DEBUG
        navigationItem.rightBarButtonItems = [optionsButton, addButton] + fixtureButtons
        #endif
    }

    private func configureContent() {
        guard isViewLoaded else { return }
        let root = contentView()
        if let content { content.rootView = root; return }
        let hosting = MobileDocumentHostingController(document: tallyDocument, rootView: root)
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        content = hosting
    }

    private func contentView() -> AnyView {
        AnyView(ContentView(document: tallyDocument.model, documentUndoManager: tallyDocument.undoManager, mobileDocumentCommands: commands)
            .disabled(tallyDocument.isRemoved || tallyDocument.editingDisabled))
    }

    func updateSearchResults(for searchController: UISearchController) {
        commands.searchText = searchController.searchBar.text ?? ""
    }

    private func presentRename() {
        guard !tallyDocument.isRemoved, !tallyDocument.editingDisabled, !isRenaming,
              presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Rename File", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.fileURL.deletingPathExtension().lastPathComponent
            field.accessibilityIdentifier = "renameFileName"
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.renameAlert = nil })
        let rename = UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert, let name = alert.textFields?.first?.text else { return }
            renameAlert = nil
            alert.dismiss(animated: true) { [weak self] in
                self?.renameFile(to: name)
            }
        }
        rename.accessibilityIdentifier = "renameFileConfirm"
        alert.addAction(rename)
        alert.preferredAction = rename
        renameAlert = alert
        present(alert, animated: true) { [weak alert] in alert?.textFields?.first?.selectAll(nil) }
    }

    private func renameFile(to name: String) {
        guard !tallyDocument.isRemoved, !tallyDocument.editingDisabled, !isRenaming,
              let onRename else { return }
        let proposedName: String
        // The document browser preserves the file's existing extension.
        do { proposedName = try TallyFileName.baseName(from: name) }
        catch { showError("Couldn’t Rename File", message: error.localizedDescription); return }
        let sourceURL = fileURL
        guard proposedName != sourceURL.deletingPathExtension().lastPathComponent else { return }
        isRenaming = true
        updateNavigation()
        Task { [weak self] in
            do {
                let renamedURL = try await onRename(sourceURL, proposedName)
                guard let self else { return }
                isRenaming = false
                guard !tallyDocument.documentState.contains(.closed), viewIfLoaded?.window != nil else { return }
                guard !tallyDocument.isRemoved, fileURL == sourceURL || fileURL == renamedURL else {
                    updateNavigation()
                    return
                }
                let renamedAccess = MobileDocumentAccess(url: renamedURL)
                if fileURL != renamedURL { tallyDocument.presentedItemDidMove(to: renamedURL) }
                fileAccess = renamedAccess
                tallyDocument.checkAfterActivation()
                updateNavigation()
            } catch {
                guard let self else { return }
                isRenaming = false
                updateNavigation()
                let cocoaError = error as NSError
                guard !(error is CancellationError), !tallyDocument.documentState.contains(.closed),
                      !(cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError),
                      !tallyDocument.isRemoved, viewIfLoaded?.window != nil else { return }
                showError("Couldn’t Rename File", message: error.localizedDescription)
            }
        }
    }

    private func shareFile() {
        guard !tallyDocument.isRemoved, !isRenaming, presentedViewController == nil else { return }
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceItem = optionsButton
        present(activity, animated: true)
    }

    private func refreshAvailability() {
        content?.rootView = contentView()
        updateNavigation()
        if tallyDocument.isRemoved {
            if let renameAlert {
                self.renameAlert = nil
                renameAlert.dismiss(animated: false) { [weak self] in self?.presentDeletionAlert() }
                return
            }
            presentDeletionAlert()
        } else {
            let previous = deletionAlert
            deletionAlert = nil
            previous?.dismiss(animated: true)
            if let recoveryPicker {
                self.recoveryPicker = nil
                recoveryPicker.dismiss(animated: true)
                cleanRecovery()
            }
        }
    }

    private func presentDeletionAlert(message: String? = nil) {
        guard tallyDocument.isRemoved, isViewLoaded, view.window != nil, deletionAlert == nil, recoveryPicker == nil else { return }
        let closesWindow = UIDevice.current.userInterfaceIdiom == .pad && UIApplication.shared.supportsMultipleScenes
        let alert = UIAlertController(title: "File Deleted", message: message ?? "Recover a copy to keep working, or close this \(closesWindow ? "window" : "file").", preferredStyle: .alert)
        let recover = UIAlertAction(title: "Recover File", style: .default) { [weak self] _ in
            self?.deletionAlert = nil
            self?.recoverFile()
        }
        recover.accessibilityIdentifier = "documentDeletedRecover"
        let close = UIAlertAction(title: closesWindow ? "Close Window" : "Close File", style: .cancel) { [weak self] _ in
            self?.deletionAlert = nil
            self?.onClose?(nil, closesWindow)
        }
        close.accessibilityIdentifier = "documentDeletedClose"
        alert.addAction(recover)
        alert.addAction(close)
        alert.preferredAction = recover
        alert.view.accessibilityIdentifier = "documentDeletedAlert"
        deletionAlert = alert
        topPresenter.present(alert, animated: true)
    }

    private func recoverFile() {
        do {
            let directory = try TallyDocumentBrowserController.makeStagingDirectory(purpose: "Recovery")
            recoveryDirectory = directory
            let filename = tallyDocument.fileURL.lastPathComponent
            let url = directory.appendingPathComponent(filename)
            try LedgerCodec.encode(tallyDocument.model.ledger).write(to: url, options: .atomic)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            picker.directoryURL = CloudDocuments.shared.documentsURL
            picker.shouldShowFileExtensions = true
            recoveryPicker = picker
            topPresenter.present(picker, animated: true)
        } catch {
            cleanRecovery()
            presentDeletionAlert(message: "The recovery copy couldn’t be prepared. Try again, or close this file.")
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        recoveryPicker = nil
        cleanRecovery()
        guard let url = urls.first else { presentDeletionAlert(); return }
        onClose?(url, false)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        recoveryPicker = nil
        cleanRecovery()
        // The picker has begun dismissal when this callback arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, tallyDocument.isRemoved else { return }
            presentDeletionAlert()
        }
    }

    private var topPresenter: UIViewController {
        var controller: UIViewController = self
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }

    private func cleanRecovery() {
        if let recoveryDirectory { try? FileManager.default.removeItem(at: recoveryDirectory) }
        recoveryDirectory = nil
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let sceneActivationObserver { NotificationCenter.default.removeObserver(sceneActivationObserver) }
        if let recoveryDirectory { try? FileManager.default.removeItem(at: recoveryDirectory) }
    }
}

private final class MobileDocumentAccess {
    private let url: URL
    private let hasAccess: Bool

    init(url: URL) {
        self.url = url
        hasAccess = url.startAccessingSecurityScopedResource()
    }

    deinit { if hasAccess { url.stopAccessingSecurityScopedResource() } }
}

private final class MobileDocumentHostingController: UIHostingController<AnyView> {
    private weak var tallyDocument: MobileTallyDocument?
    override var undoManager: UndoManager? { tallyDocument?.undoManager }

    init(document: MobileTallyDocument, rootView: AnyView) {
        tallyDocument = document
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private extension UIViewController {
    func makeTallyOptionsButton(fileActions: [UIMenuElement] = []) -> UIBarButtonItem {
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape"), identifier: UIAction.Identifier("tallySettings")) { [weak self] _ in
            (self as? TallyDocumentBrowserController)?.cancelLaunchRestoration()
            self?.presentTallySettings()
        }
        let privacy = UIAction(title: "Privacy & Support", image: UIImage(systemName: "hand.raised"), identifier: UIAction.Identifier("tallyPrivacySupport")) { [weak self] _ in
            (self as? TallyDocumentBrowserController)?.cancelLaunchRestoration()
            self?.presentPrivacySupport()
        }
        let children: [UIMenuElement] = fileActions.isEmpty ? [settings, privacy] : [
            UIMenu(options: .displayInline, children: fileActions),
            UIMenu(options: .displayInline, children: [settings, privacy])
        ]
        let button = UIBarButtonItem(title: "Tally options", image: UIImage(systemName: "ellipsis"), primaryAction: nil, menu: UIMenu(children: children))
        button.accessibilityIdentifier = "tallyOptionsButton"
        button.accessibilityLabel = "Tally options"
        return button
    }

    func presentTallySettings() {
        guard presentedViewController == nil else { return }
        let controller = UIHostingController(rootView: TallySettingsView { [weak self] in
            self?.dismiss(animated: true)
        })
        controller.modalPresentationStyle = .pageSheet
        controller.preferredContentSize = CGSize(width: 500, height: 320)
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        present(controller, animated: true)
    }

    func presentPrivacySupport() {
        guard presentedViewController == nil else { return }
        let controller = UIHostingController(rootView: PrivacySupportView { [weak self] in
            self?.dismiss(animated: true)
        })
        controller.modalPresentationStyle = .pageSheet
        controller.preferredContentSize = CGSize(width: 600, height: 640)
        controller.sheetPresentationController?.detents = [.large()]
        present(controller, animated: true)
    }

    func showError(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
