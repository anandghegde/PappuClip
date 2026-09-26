import AppKit
import Foundation
import PappuAX
import PappuAnalysis
import PappuCore
import PappuDiagnostics
import PappuExtensions
import PappuRuntime
import PappuSelection
import PappuSettings
import PappuSurfaces

/// The whole app, built once and wired together (architecture §19).
///
/// Every other file in PappuKit is a piece that takes its collaborators as arguments and can therefore
/// be built out of fakes in a test. This is the one place that names the real ones, and it is the price
/// of that arrangement: somewhere the seams have to be sewn up, and it is better that it happens in a
/// single file whose only job is the sewing than in twenty initialisers with system defaults hidden in
/// them.
///
/// There is no test for this file, as the house style has it for the files that touch the system: the
/// order things are built in is the assertion, and the only way to check it is to run the app. What can
/// be checked without running it is checked — `AppResources` has a test that reads the real bundle, and
/// every part named below has its own suite.
///
/// The order is not arbitrary. The tag comes first because two different parts post synthetic events
/// and both must be recognisable as ours; the tap comes next because it is what every attempt's clock
/// and every epoch is read from; the stores come before anything that reads a setting; and the bridge
/// comes before the bar but is handed the bar afterwards, because each needs the other and one of them
/// has to be second.
@MainActor
public final class AppAssembly: SelectionInstalling {
    public let resources: AppResources

    private let taps: EventTapService
    private let rules: PrivacyRulesStore
    private let shortcuts: ShortcutStore
    private let barPreferences: BarPreferences
    private let onboarding: OnboardingStore
    private let frontmost: FrontmostApp
    private let coexistence: CoexistenceMonitor
    private let hotkeys: HotkeyService
    private let watcher: AttemptWatcher
    private let health: TapHealthMonitor
    private let accessibility: AccessibilityMonitor
    private let bridge: SelectionBridge
    private let bar: BarController
    private let coordinator: ActivationCoordinator
    private let statusItem: MenuBarItem
    private let settingsWindow: SettingsWindow
    private let attention: ScriptAttention
    /// Nil when the extension library could not be opened; the app then runs its built-ins only.
    private let host: ExtensionHost?
    private let settingsModel: SettingsModel
    private let consentWindow: ConsentWindow
    private let onboardingWindow: OnboardingWindow
    private let consoleWindow: DebugConsoleWindow

    /// The loops that read the three streams. Held so that `stop` can end them; an `AsyncStream` whose
    /// consumer is a detached task nobody kept would run for the life of the process either way, but a
    /// test host that builds two assemblies would then have two taps feeding two coordinators.
    private var tasks: [Task<Void, Never>] = []

    /// Asynchronous because the Accessibility probes live on `AXActor` and must be made there
    /// (architecture §14). The caller is `applicationDidFinishLaunching`, which cannot wait, so the
    /// first thing the app does is start a task; nothing is on screen until it gets this far anyway.
    public init(resources: AppResources, defaults: UserDefaults = .standard) async {
        self.resources = resources
        let ax = await Self.accessibilityProbes()

        // One tag for the process. Everything we post — the copy behind a selection read, a paste, a
        // cut — carries it, and the tap drops what carries it, which is what keeps the app from
        // treating its own keystrokes as the user's (architecture §3.2, ACT-9a).
        let tag = SyntheticEventTag.random()
        let taps = EventTapService(installer: SessionTapInstaller(ownTag: tag))

        let storage = UserDefaultsStorage(defaults)
        let rules = PrivacyRulesStore(storage: storage)
        let shortcuts = ShortcutStore(storage: storage)
        let barPreferences = BarPreferences(storage: storage)
        let onboarding = OnboardingStore(storage: storage)

        // A closure and not a copy: the gate is built once and every attempt after a setting changes
        // must be judged against the new one (architecture §4.4).
        let gate = PrivacyGate(rules: rules.reader)
        let policies = DetectionPolicyStore(resources.policies)

        let frontmost = FrontmostApp()
        // PopClip running takes synthetic copy off the automatic path (ACT-10j), and a clipboard manager
        // lengthens the settle (ACT-10i). The coordinator and the chain both ask, and both ask this.
        let coexistence = CoexistenceMonitor()
        let pasteboard = SystemPasteboard()

        let broker = ClipboardBroker(
            pasteboard: pasteboard,
            input: taps,
            copy: SystemSyntheticCopy(tag: tag),
            pasting: SystemSyntheticPaste(tag: tag)
        )
        let chain = SelectionStrategyChain(
            reader: ax.selection,
            policies: policies,
            broker: broker,
            coexistence: coexistence.reader
        )
        let watcher = AttemptWatcher()

        let verifier = DestinationVerifier(
            gate: gate,
            probe: ax.destination,
            policies: policies,
            epochs: taps,
            frontmost: frontmost.reader
        )
        let manager = InvocationManager(verifier: verifier, probe: ax.destination, epochs: taps)

        // The installed extensions (M2). After the manager, because a revocation has to reach what the
        // extension is running (SEC-4b); before the bridge, which reads the catalog, the approvals and
        // the options from it. A library that cannot be opened — a disk that refuses the database — is
        // an app with its built-ins and no extensions, not an app that does not start.
        // What extensions print and how their actions end (DIA-1). The JavaScript helper is the first
        // thing that writes to it. PappuClipJSHost.xpc is started on the first JavaScript action, or at
        // launch when an approved module extension needs describing (JS-12).
        let console = DebugConsole()
        let javaScript = JSHostClient(console: console)
        // The helper also reads each extension's JavaScript for what it can reach (EXM-5f).
        let host = (try? ExtensionLibrary(paths: .standard, scanner: javaScript)).map { library in
            ExtensionHost(
                library: library,
                secrets: KeychainSecretStore(),
                builtins: resources.builtins,
                modules: javaScript,
                console: console,
                invalidate: { owner in await manager.invalidate(ownedBy: owner) }
            )
        }
        let editor = SelectionEditor(
            cut: SystemSyntheticCut(tag: tag),
            paste: SystemSyntheticPaste(tag: tag),
            manager: manager
        )
        let mutator = TextMutator(clipboard: broker, manager: manager)
        let runner = BuiltinRunner(
            manager: manager,
            editor: editor,
            mutator: mutator,
            clipboard: broker,
            urls: SystemURLOpener(),
            engines: resources.engines
        )
        let scripts = RunnerClient()
        let shortcutRunner = SystemShortcutRunner()
        let extensions = ExtensionRunner(
            manager: manager,
            editor: editor,
            mutator: mutator,
            presser: KeyPresser(poster: SystemSyntheticKeyPress(tag: tag), manager: manager),
            clipboard: broker,
            urls: SystemURLOpener(),
            shortcuts: shortcutRunner,
            shell: SystemShellScriptRunner(),
            // AppleScripts and Services both run in PappuClipRunner.xpc, over one session.
            appleScripts: scripts,
            services: scripts,
            javaScript: javaScript,
            system: SystemHostServices(),
            installed: SystemInstalledApps(),
            // M3 week 4: a script's network (JS-8, SEC-6) and its external scripts (JS-5), behind the
            // dispatcher's checks.
            hostCalls: [
                NetworkHostCalls(manager: manager),
                ScriptHostCalls(manager: manager, appleScripts: scripts, shortcuts: shortcutRunner),
            ]
        )

        let builtinCatalog = resources.catalog
        let catalog: @Sendable () -> ActionCatalog = { host?.catalog ?? builtinCatalog }
        let bridge = SelectionBridge(
            catalog: catalog,
            gate: gate,
            probe: ax.context,
            analyzer: ContentAnalyzer(schemes: resources.schemes, domains: resources.domains),
            manager: manager,
            runner: runner,
            extensions: extensions,
            // Asked once per attempt. Paste is offered only when there is text to paste, and the
            // clipboard belongs to the whole machine: what was in it when the last bar was drawn says
            // nothing about what is in it now (ACT-10).
            conditions: {
                BuiltinConditions(
                    clipboardHasText: pasteboard.itemTypes().contains {
                        $0.contains(PasteboardRepresentation.plainText)
                    }
                )
            },
            // The focused field's own secureness was settled by the read that holds the permit. What
            // can still change between that read and the bar is the system-wide flag, and that is the
            // half asked for here (PRV-2).
            secureInput: { SecureInput.state(focusedFieldIsSecure: false) },
            // EXM-5: nothing an extension wrote runs without the store's approval of its active bytes.
            resolver: ActionResolver { action in host?.approval(for: action) ?? ExecutionApproval.bundled(action) },
            options: { host?.options ?? [:] },
            runtimeOptions: { action in host?.runtimeOptions(for: action) ?? [:] }
        )

        let bar = BarController(
            window: BarWindow(),
            content: bridge,
            invoker: bridge,
            screens: AppKitScreens(),
            appearance: AppKitAppearance(),
            measurer: BarItemMeasurer(),
            keys: taps,
            settings: barPreferences.settings
        )

        let coordinator = ActivationCoordinator(
            gate: gate,
            policies: policies,
            probe: ax.focus,
            reader: chain,
            presenter: bar,
            watcher: watcher,
            frontmost: frontmost.reader,
            popClipIsRunning: { coexistence.current.popClipIsRunning }
        )

        let hotkeys = HotkeyService(registrar: SystemHotkeyRegistrar())
        let accessibility = AccessibilityMonitor(store: onboarding)
        let health = TapHealthMonitor(service: taps, triggers: WorkspaceHealthTriggers())

        // Settings changes to an extension reach the bar through the host, and the Actions tab after it.
        // The model is made second, so the first is handed it through a weak reference.
        weak var settingsRef: SettingsModel?
        let extensionsModel = host.map { host in
            ExtensionsModel(library: host.library, secrets: host.secrets) { change in
                await host.handle(change)
                settingsRef?.refresh()
            }
        }
        let settingsModel = SettingsModel(
            rules: rules,
            shortcuts: shortcuts,
            bar: barPreferences,
            onboarding: onboarding,
            catalog: catalog,
            displayName: Self.displayName,
            extensions: extensionsModel,
            openAccessibilitySettings: { accessibility.openSystemSettings() }
        )
        settingsRef = settingsModel
        let settingsWindow = SettingsWindow(model: settingsModel)
        let onboardingWindow = OnboardingWindow(model: OnboardingModel(
            store: onboarding,
            requestGrant: { accessibility.requestGrant() },
            openAccessibilitySettings: { accessibility.openSystemSettings() }
        ))

        // Built fresh every time the menu opens, from the settings and the grant as they stand: the
        // menu is the one surface that is looked at while nothing else is happening, and a tick left
        // over from an hour ago is worse than no menu (ACT-18).
        let consoleWindow = DebugConsoleWindow(console: console)

        // The status item is made before the assembly is, so a drop reaches it through a weak reference.
        weak var assemblyRef: AppAssembly?
        let statusItem = MenuBarItem(
            menu: { MenuBarMenu(rules: rules.rules, grant: onboarding.grant) },
            perform: { [rules] command in
                switch command {
                case .appearAutomatically:
                    rules.setAppearAutomatically(!rules.appearAutomatically)
                case .pauseForOneHour:
                    rules.pauseForOneHour()
                case .pauseUntilResumed:
                    rules.pauseUntilResumed()
                case .resume:
                    rules.resume()
                case .onboarding:
                    onboardingWindow.show()
                case .settings:
                    settingsWindow.show()
                case .debugConsole:
                    consoleWindow.show()
                case .quit:
                    NSApp.terminate(nil)
                }
            },
            // EXM-3: a file dropped on the icon is opened as the Finder would open it.
            drop: { urls in
                guard let assembly = assemblyRef else { return }
                Task { await assembly.open(urls) }
            }
        )

        self.taps = taps
        self.rules = rules
        self.shortcuts = shortcuts
        self.barPreferences = barPreferences
        self.onboarding = onboarding
        self.frontmost = frontmost
        self.coexistence = coexistence
        self.hotkeys = hotkeys
        self.watcher = watcher
        self.health = health
        self.accessibility = accessibility
        self.bridge = bridge
        self.bar = bar
        self.coordinator = coordinator
        self.statusItem = statusItem
        self.settingsWindow = settingsWindow
        // A script that asked for its settings gets its extension's options sheet (ALM-6).
        self.attention = ScriptAttention(openOptions: { title, owner in
            settingsWindow.show()
            settingsModel.showOptions(title, owner: owner)
        })
        self.host = host
        self.settingsModel = settingsModel
        self.consentWindow = ConsentWindow()
        self.onboardingWindow = onboardingWindow
        self.consoleWindow = consoleWindow
        assemblyRef = self
    }

    /// Everything that begins talking to the system, in the order it may begin.
    ///
    /// Asynchronous for one reason: the bridge is an actor and has to be handed the bar. The caller is
    /// `applicationDidFinishLaunching`, which cannot wait, so the app's first visible moment is this
    /// task's first suspension — which is why the status item goes up inside it rather than after it.
    public func start() async {
        // Before the bar can appear, so that its first resolution already has the installed extensions.
        if let host {
            await host.start()
            await settingsModel.extensions?.refresh()
            settingsModel.refresh()
        }
        await bridge.attach(bar)
        await bridge.attach(attention: attention)
        // Only with a library to install into; without one the bar does not offer it.
        if host != nil { await bridge.attach(installer: self) }
        bar.prepare()
        statusItem.install()

        // Before the tap, so that the first answer about the grant is the one the tap's own success or
        // failure then confirms (ONB-4: trusted and refused is a different state from not trusted).
        accessibility.start()
        frontmost.start()
        coexistence.start()
        watcher.start()
        health.start()

        // The one fact about the grant that no API reports: `CGEvent.tapCreate` fails for an untrusted
        // process, and succeeds while returning nothing for a stale one.
        accessibility.noteTap(created: taps.start())

        hotkeys.use(shortcuts.shortcut)
        shortcuts.onChange { [hotkeys] shortcut in hotkeys.use(shortcut) }
        barPreferences.onChange { [bar] settings in
            Task { @MainActor in bar.settings = settings }
        }
        // A pause, an exclusion or a block arriving while a bar is up takes that bar away; the
        // coordinator is what knows there is an attempt to retire (ACT-16a, RUN-3).
        rules.onChange { [coordinator] _ in
            Task { await coordinator.invalidate(.privacyStateChanged) }
        }

        tasks.append(Task { [coordinator, taps] in await coordinator.run(taps.events) })
        tasks.append(Task { [coordinator, watcher] in await coordinator.watch(watcher.notices) })
        tasks.append(Task { [coordinator, hotkeys] in
            for await _ in hotkeys.presses {
                await coordinator.activate(route: .hotkey)
            }
        })

        // Last, because it takes the screen: a first run should find the app already working behind the
        // window it is being explained in. A launch that owes the user nothing opens nothing (ONB-1).
        if onboardingWindow.hasSomethingToShow {
            onboardingWindow.show()
        }
    }

    /// The reverse, for a quit that wants to be tidy and for a host that builds more than one.
    public func stop() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        health.stop()
        taps.stop()
        hotkeys.use(nil)
        await watcher.stop()
        frontmost.stop()
        coexistence.stop()
        accessibility.stop()
        statusItem.remove()
    }

    /// Files the Finder asked the app to open (EXM-1): each extension is reviewed, one at a time, in the
    /// install sheet every route goes through (EXM-5). Failures are said, one alert per file.
    public func open(_ urls: [URL]) async {
        await install(urls.compactMap(ExtensionLibrary.Source.file))
    }

    private func install(_ sources: [ExtensionLibrary.Source]) async {
        guard let host else { return }
        let consentWindow = self.consentWindow
        let results = await host.install(sources: sources) { proposal in
            await consentWindow.review(proposal) { identity in
                host.snapshot.installed[identity.description]?.manifest.name.text(for: .current)
            }
        }
        await settingsModel.extensions?.refresh()
        settingsModel.refresh()
        for case .failure(let error) in results {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = ExtensionStrings.failed(String(describing: error))
            NSApp.activate()
            alert.runModal()
        }
    }

    /// The bar's Install Extension offer (EXM-2), reviewed like a file.
    public func installExtension(fromSelection text: String) async {
        await install([.selectedText(text)])
    }

    /// Opened from the menu, and from the onboarding window when it hands the user on.
    public func showSettings() {
        settingsWindow.show()
    }

    /// The four Accessibility readers, which share one serial queue of their own and are made on it.
    ///
    /// One `AXDestinationProbe` between the verifier and the manager, and deliberately: it is where an
    /// invocation's captured elements live, and two of them would be two sets of elements with one
    /// invocation looking at the wrong one.
    private struct AccessibilityProbes: Sendable {
        var focus: AXFocusProbe
        var selection: AXSelectionReader
        var destination: AXDestinationProbe
        var context: ContextProbe
    }

    @AXActor
    private static func accessibilityProbes() -> AccessibilityProbes {
        AccessibilityProbes(
            focus: AXFocusProbe(),
            selection: AXSelectionReader(),
            destination: AXDestinationProbe(),
            context: ContextProbe()
        )
    }

    /// What Settings → Privacy calls an app the user has excluded. A bundle ID is what is stored, and a
    /// bundle ID is not a name anyone would recognise in a list.
    private static let displayName: @Sendable (String) -> String? = { bundleID in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
