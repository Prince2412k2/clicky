//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var displayedResponseText = ""
    @Published private(set) var interactionErrorMessage: String?
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the selected model's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    @Published private(set) var screenAnnotations: [ScreenAnnotation] = []

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    private lazy var screenshotPromptWindowManager = ScreenshotPromptWindowManager(
        onSubmit: { [weak self] prompt, screenCapture in
            self?.sendPromptWithScreenshot(
                transcript: prompt,
                suppliedScreenCaptures: [screenCapture]
            )
        }
    )
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    let chatGPTAuthenticationManager = ChatGPTAuthenticationManager()
    private lazy var openAIResponsesAPI = OpenAIResponsesAPI(
        authenticationManager: chatGPTAuthenticationManager
    )
    private let directAIClient = OpenClickyDirectAIClient()
    private let systemTTSClient = SystemTTSClient()

    /// Conversation history so the selected model remembers prior exchanges within a session.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var screenshotShortcutCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var annotationClearTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    var visualPromptPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    @Published var selectedAIProvider = OpenClickyAIProvider(
        rawValue: UserDefaults.standard.string(forKey: "selectedAIProvider") ?? ""
    ) ?? .chatGPT
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedAIModel") ?? "gpt-5.2"
    @Published var speechOutput = OpenClickySpeechOutput(
        rawValue: UserDefaults.standard.string(forKey: "speechOutput") ?? ""
    ) ?? .macVoice
    @Published private(set) var discoveredModels: [OpenAIModelOption] = []
    @Published private(set) var providerErrorMessage: String?
    private var discoveredModelsProvider: OpenClickyAIProvider?

    var availableModelNames: [String] {
        if discoveredModelsProvider == selectedAIProvider && !discoveredModels.isEmpty {
            return discoveredModels.map(\.id)
        }
        return selectedAIProvider.suggestedModels
    }

    func setSelectedAIProvider(_ provider: OpenClickyAIProvider) {
        selectedAIProvider = provider
        discoveredModels = []
        discoveredModelsProvider = nil
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedAIProvider")
        let savedModel = UserDefaults.standard.string(forKey: "selectedAIModel.\(provider.rawValue)")
        setSelectedModel(savedModel ?? provider.defaultModel)
        providerErrorMessage = nil
        if provider == .ollama
            || (provider == .chatGPT && chatGPTAuthenticationManager.isSignedIn)
            || (provider.requiresAPIKey && hasAPIKey(for: provider)) {
            refreshAvailableModels()
        }
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedAIModel")
        UserDefaults.standard.set(model, forKey: "selectedAIModel.\(selectedAIProvider.rawValue)")
    }

    func setSpeechOutput(_ output: OpenClickySpeechOutput) {
        speechOutput = output
        UserDefaults.standard.set(output.rawValue, forKey: "speechOutput")
        if output == .textOnly {
            systemTTSClient.stopPlayback()
        }
    }

    func hasAPIKey(for provider: OpenClickyAIProvider) -> Bool {
        OpenClickyCredentialStore.apiKey(for: provider) != nil
    }

    func saveAPIKey(_ apiKey: String, for provider: OpenClickyAIProvider) throws {
        try OpenClickyCredentialStore.saveAPIKey(apiKey, for: provider)
        providerErrorMessage = nil
        if selectedAIProvider == provider {
            refreshAvailableModels()
        }
    }

    func removeAPIKey(for provider: OpenClickyAIProvider) {
        OpenClickyCredentialStore.deleteAPIKey(for: provider)
    }

    func clearConversation() {
        conversationHistory.removeAll()
        displayedResponseText = ""
        clearDetectedElementLocation()
        clearScreenAnnotations()
    }

    func refreshAvailableModels() {
        let provider = selectedAIProvider
        Task {
            do {
                let models: [OpenAIModelOption]
                if provider == .chatGPT {
                    guard chatGPTAuthenticationManager.isSignedIn else { return }
                    models = try await openAIResponsesAPI.listAvailableModels()
                } else {
                    models = try await directAIClient.listModels(
                        provider: provider,
                        apiKey: OpenClickyCredentialStore.apiKey(for: provider)
                    )
                }
                guard selectedAIProvider == provider else { return }
                discoveredModels = models
                discoveredModelsProvider = provider
                if !models.contains(where: { $0.id == selectedModel }), let firstModel = models.first {
                    setSelectedModel(firstModel.id)
                }
            } catch {
                providerErrorMessage = error.localizedDescription
            }
        }
    }

    @Published var isOpenClickyEnabled: Bool = UserDefaults.standard.object(forKey: "isOpenClickyEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isOpenClickyEnabled")

    func setOpenClickyEnabled(_ enabled: Bool) {
        isOpenClickyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isOpenClickyEnabled")

        if enabled {
            refreshAllPermissions()
            if visualPromptPermissionsGranted {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            } else {
                NotificationCenter.default.post(name: .openClickyShowPanel, object: nil)
            }
        } else {
            globalPushToTalkShortcutMonitor.stop()
            buddyDictationManager.cancelCurrentDictation()
            pendingKeyboardShortcutStartTask?.cancel()
            currentResponseTask?.cancel()
            currentResponseTask = nil
            systemTTSClient.stopPlayback()
            clearScreenAnnotations()
            displayedResponseText = ""
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func start() {
        refreshAllPermissions()
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindScreenshotShortcut()
        if selectedAIProvider == .ollama
            || (selectedAIProvider == .chatGPT && chatGPTAuthenticationManager.isSignedIn)
            || (selectedAIProvider.requiresAPIKey && hasAPIKey(for: selectedAIProvider)) {
            refreshAvailableModels()
        }

        if visualPromptPermissionsGranted && isOpenClickyEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        annotationClearTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        screenshotShortcutCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility && isOpenClickyEnabled {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during setup.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    if visualPromptPermissionsGranted && !isOverlayVisible && isOpenClickyEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func bindScreenshotShortcut() {
        screenshotShortcutCancellable = globalPushToTalkShortcutMonitor
            .screenshotShortcutPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.presentScreenshotPrompt()
            }
    }

    private func presentScreenshotPrompt() {
        guard isOpenClickyEnabled else { return }
        guard hasScreenRecordingPermission && hasScreenContentPermission else {
            interactionErrorMessage = "Grant Screen Recording and Screen Content access to use screenshot prompts."
            NotificationCenter.default.post(name: .openClickyShowPanel, object: nil)
            return
        }

        interactionErrorMessage = nil
        NotificationCenter.default.post(name: .openClickyDismissPanel, object: nil)
        Task {
            do {
                let screenCapture = try await CompanionScreenCaptureUtility.captureScreenContainingPointerAsJPEG()
                screenshotPromptWindowManager.show(
                    screenCapture: screenCapture,
                    providerName: selectedAIProvider.displayName,
                    modelName: selectedModel
                )
            } catch {
                let message = "Could not capture the current display: \(error.localizedDescription)"
                interactionErrorMessage = message
                displayedResponseText = message
            }
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard isOpenClickyEnabled else { return }
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .openClickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            systemTTSClient.stopPlayback()
            clearDetectedElementLocation()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.sendPromptWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionResponseSystemPrompt = """
    You are OpenClicky, a privacy-first companion that lives in the user's macOS menu bar. The user asked for help and explicitly shared one or more screenshots with this request. This is an ongoing conversation, so use the supplied conversation history when relevant.

    rules:
    - Default to a concise, direct answer. Expand when the user asks for depth.
    - Be warm and precise. Do not add filler or unnecessary follow-up questions.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    teaching annotations:
    when visual guidance would help, draw directly over the shared screenshot with up to four DRAW tags. put every tag at the very end of the response after the POINT tag. coordinates use the screenshot's top-left pixel origin.

    available tags:
    - [DRAW:arrow:startX,startY,endX,endY:short label] draws an arrow toward a target.
    - [DRAW:box:x,y,width,height:short label] outlines a UI region.
    - [DRAW:highlight:x,y,width,height:short label] softly highlights a region.
    - [DRAW:pointer:x,y:short label] places a pulsing pointer.

    use annotations to teach multi-step spatial ideas, compare areas, or make a target unmistakable. keep labels to one through four words. do not draw when the question is unrelated to the screenshot. never invent coordinates outside the supplied image dimensions.

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it to the selected provider, and optionally
    /// speaks the response through macOS. A [POINT:x,y:label] tag makes the
    /// buddy fly to the referenced element.
    private func sendPromptWithScreenshot(
        transcript: String,
        suppliedScreenCaptures: [CompanionScreenCapture]? = nil
    ) {
        currentResponseTask?.cancel()
        systemTTSClient.stopPlayback()
        clearScreenAnnotations()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            displayedResponseText = ""

            do {
                let screenCaptures: [CompanionScreenCapture]
                if let suppliedScreenCaptures {
                    screenCaptures = suppliedScreenCaptures
                } else {
                    screenCaptures = [try await CompanionScreenCaptureUtility.captureScreenContainingPointerAsJPEG()]
                }

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let fullResponseText: String
                let outputGuidance = speechOutput == .macVoice
                    ? "The response will be spoken aloud. Use short, natural sentences and avoid markdown or code dumps."
                    : "The response will be read on screen. Use clear formatting when it improves readability."
                let systemPrompt = Self.companionResponseSystemPrompt + "\n\n" + outputGuidance
                if selectedAIProvider == .chatGPT {
                    let response = try await openAIResponsesAPI.analyzeImageStreaming(
                        images: labeledImages,
                        model: selectedModel,
                        systemPrompt: systemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        onTextChunk: { _ in }
                    )
                    fullResponseText = response.text
                } else {
                    fullResponseText = try await directAIClient.respond(
                        provider: selectedAIProvider,
                        model: selectedModel,
                        apiKey: OpenClickyCredentialStore.apiKey(for: selectedAIProvider),
                        images: labeledImages,
                        systemPrompt: systemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript
                    )
                }

                guard !Task.isCancelled else { return }

                // Parse the provider-independent [POINT:...] tag.
                let annotationParseResult = ScreenAnnotationParser.parse(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: annotationParseResult.responseText)
                let spokenText = parseResult.spokenText
                displayedResponseText = spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let targetScreenCapture {
                    screenAnnotations = annotationParseResult.annotations.compactMap { parsedAnnotation in
                        Self.makeScreenAnnotation(
                            from: parsedAnnotation,
                            screenCapture: targetScreenCapture
                        )
                    }
                    if screenAnnotations.isEmpty,
                       let pointCoordinate = parseResult.coordinate {
                        screenAnnotations = [Self.makePointerAnnotation(
                            pointCoordinate: pointCoordinate,
                            label: parseResult.elementLabel,
                            screenCapture: targetScreenCapture
                        )]
                    }
                    scheduleAnnotationClearIfNeeded()
                }

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    let globalLocation = Self.convertScreenshotPointToGlobalAppKit(
                        pointCoordinate,
                        screenCapture: targetScreenCapture
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = targetScreenCapture.displayFrame
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }


                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if speechOutput == .macVoice {
                        systemTTSClient.speakText(spokenText)
                        voiceState = .responding
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                showResponseError(error.localizedDescription)
            }

            if !Task.isCancelled {
                voiceState = .idle
            }
        }
    }

    private func showResponseError(_ details: String) {
        providerErrorMessage = details
        displayedResponseText = "OpenClicky could not complete that request. Check your provider settings and try again."
        if speechOutput == .macVoice {
            systemTTSClient.speakText(displayedResponseText)
            voiceState = .responding
        }
    }

    func clearScreenAnnotations() {
        annotationClearTask?.cancel()
        annotationClearTask = nil
        screenAnnotations = []
    }

    private func scheduleAnnotationClearIfNeeded() {
        annotationClearTask?.cancel()
        guard !screenAnnotations.isEmpty else { return }
        annotationClearTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            screenAnnotations = []
        }
    }

    static func makeScreenAnnotation(
        from parsedAnnotation: ParsedScreenAnnotation,
        screenCapture: CompanionScreenCapture
    ) -> ScreenAnnotation? {
        let coordinates = parsedAnnotation.coordinates
        guard coordinates.count == (parsedAnnotation.kind == .pointer ? 2 : 4) else { return nil }

        let startPixelLocation = CGPoint(x: coordinates[0], y: coordinates[1])
        let endPixelLocation: CGPoint
        switch parsedAnnotation.kind {
        case .arrow:
            endPixelLocation = CGPoint(x: coordinates[2], y: coordinates[3])
        case .box, .highlight:
            endPixelLocation = CGPoint(
                x: coordinates[0] + max(coordinates[2], 1),
                y: coordinates[1] + max(coordinates[3], 1)
            )
        case .pointer:
            endPixelLocation = startPixelLocation
        }

        return ScreenAnnotation(
            kind: parsedAnnotation.kind,
            startLocation: convertScreenshotPointToGlobalAppKit(
                startPixelLocation,
                screenCapture: screenCapture
            ),
            endLocation: convertScreenshotPointToGlobalAppKit(
                endPixelLocation,
                screenCapture: screenCapture
            ),
            label: parsedAnnotation.label,
            displayFrame: screenCapture.displayFrame
        )
    }

    private static func makePointerAnnotation(
        pointCoordinate: CGPoint,
        label: String?,
        screenCapture: CompanionScreenCapture
    ) -> ScreenAnnotation {
        let globalLocation = convertScreenshotPointToGlobalAppKit(
            pointCoordinate,
            screenCapture: screenCapture
        )
        return ScreenAnnotation(
            kind: .pointer,
            startLocation: globalLocation,
            endLocation: globalLocation,
            label: label == "none" ? nil : label,
            displayFrame: screenCapture.displayFrame
        )
    }

    static func convertScreenshotPointToGlobalAppKit(
        _ screenshotPoint: CGPoint,
        screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = max(CGFloat(screenCapture.screenshotWidthInPixels), 1)
        let screenshotHeight = max(CGFloat(screenCapture.screenshotHeightInPixels), 1)
        let clampedX = max(0, min(screenshotPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPoint.y, screenshotHeight))
        let localX = clampedX * (CGFloat(screenCapture.displayWidthInPoints) / screenshotWidth)
        let localYFromTop = clampedY * (CGFloat(screenCapture.displayHeightInPoints) / screenshotHeight)
        return CGPoint(
            x: screenCapture.displayFrame.minX + localX,
            y: screenCapture.displayFrame.minY + CGFloat(screenCapture.displayHeightInPoints) - localYFromTop
        )
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from a model response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the model said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from a response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}
