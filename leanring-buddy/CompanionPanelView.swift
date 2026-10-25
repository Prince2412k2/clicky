import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var authenticationManager: ChatGPTAuthenticationManager
    @ObservedObject private var localModelState: LocalSpeechModelState
    @ObservedObject private var updater: OpenClickyUpdater
    @State private var apiKeyInput = ""
    @State private var apiKeySaveMessage: String?
    @State private var isModelPickerPresented = false
    @State private var modelSearchText = ""

    private let panelWidth: CGFloat = 310

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        authenticationManager = companionManager.chatGPTAuthenticationManager
        localModelState = .shared
        updater = .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            settingsSection

            if !companionManager.allPermissionsGranted {
                Divider()
                permissionsSection
            }

            Divider()
            actionsSection
        }
        .frame(width: panelWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear {
            if updater.state == .idle {
                updater.checkForUpdates()
            }
        }
        .onChange(of: authenticationManager.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                companionManager.refreshAvailableModels()
            }
        }
        .alert(
            "Use your ChatGPT plan?",
            isPresented: $authenticationManager.shouldShowPlanUsageConfirmation
        ) {
            Button("Continue") {
                authenticationManager.acknowledgePlanUsage()
            }
        } message: {
            Text("Prompts and invoked screenshots go directly to OpenAI using your eligible ChatGPT plan.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 36, height: 36)
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenClicky")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle(
                "OpenClicky",
                isOn: Binding(
                    get: { companionManager.isOpenClickyEnabled },
                    set: { companionManager.setOpenClickyEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.accentColor)
            .help(companionManager.isOpenClickyEnabled ? "Stop OpenClicky" : "Start OpenClicky")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var settingsSection: some View {
        VStack(spacing: 0) {
            menuRow(
                title: "Provider",
                iconName: "network",
                selection: companionManager.selectedAIProvider.displayName
            ) {
                ForEach(OpenClickyAIProvider.allCases) { provider in
                    Button {
                        apiKeyInput = ""
                        apiKeySaveMessage = nil
                        companionManager.setSelectedAIProvider(provider)
                    } label: {
                        menuSelectionLabel(
                            provider.displayName,
                            isSelected: companionManager.selectedAIProvider == provider
                        )
                    }
                }
            }

            modelPickerRow

            menuRow(
                title: "Voice",
                iconName: "waveform",
                selection: companionManager.speechOutput.displayName
            ) {
                ForEach(OpenClickySpeechOutput.allCases) { output in
                    Button {
                        companionManager.setSpeechOutput(output)
                    } label: {
                        menuSelectionLabel(
                            output.displayName,
                            isSelected: companionManager.speechOutput == output
                        )
                    }
                }
            }

            menuRow(
                title: "Transcription",
                iconName: "mic",
                selection: companionManager.buddyDictationManager.isPreparingTranscriptionProvider
                    ? "Preparing…"
                    : companionManager.buddyDictationManager.transcriptionProviderDisplayName
            ) {
                Button {
                    companionManager.buddyDictationManager.setTranscriptionProvider(.localParakeet)
                } label: {
                    menuSelectionLabel(
                        "Parakeet Local",
                        isSelected: companionManager.buddyDictationManager.selectedTranscriptionProvider == .localParakeet
                    )
                }
                Button {
                    companionManager.buddyDictationManager.setTranscriptionProvider(.appleSpeech)
                } label: {
                    menuSelectionLabel(
                        "Apple Speech",
                        isSelected: companionManager.buddyDictationManager.selectedTranscriptionProvider == .appleSpeech
                    )
                }
                Button {
                    companionManager.buddyDictationManager.setTranscriptionProvider(.openAI)
                } label: {
                    menuSelectionLabel(
                        "OpenAI API",
                        isSelected: companionManager.buddyDictationManager.selectedTranscriptionProvider == .openAI
                    )
                }
            }

            Divider()
                .padding(.vertical, 5)

            accountSection
            if shouldShowAnyLocalModelState {
                localModelsSection
            }

            if let errorMessage = visibleErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var accountSection: some View {
        if companionManager.selectedAIProvider == .chatGPT {
            if authenticationManager.isSignedIn {
                Menu {
                    Button("Manage Usage") {
                        if let usageURL = URL(string: "https://chatgpt.com/settings/usage") {
                            NSWorkspace.shared.open(usageURL)
                        }
                    }
                    Button("Use Another Account or Workspace") {
                        authenticationManager.signInWithAnotherAccountOrWorkspace()
                    }
                    Divider()
                    Button("Disconnect", role: .destructive) {
                        authenticationManager.signOut()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(authenticationManager.accountEmail ?? "ChatGPT")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text("Connected")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .pointerCursor()
            } else {
                Button {
                    authenticationManager.signIn()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 16))
                            .frame(width: 22)
                        Text(authenticationManager.isSigningIn ? "Connecting…" : "Connect ChatGPT")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                }
                .buttonStyle(.plain)
                .disabled(authenticationManager.isSigningIn)
                .pointerCursor()
            }
        } else if companionManager.selectedAIProvider.requiresAPIKey {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                SecureField(
                    companionManager.hasAPIKey(for: companionManager.selectedAIProvider)
                        ? "Key stored in Keychain"
                        : "API key",
                    text: $apiKeyInput
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))

                Button {
                    saveAPIKey()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor()

                if companionManager.hasAPIKey(for: companionManager.selectedAIProvider) {
                    Button {
                        companionManager.removeAPIKey(for: companionManager.selectedAIProvider)
                        apiKeyInput = ""
                        apiKeySaveMessage = "Removed from Keychain"
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove API key")
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            if let apiKeySaveMessage {
                Text(apiKeySaveMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 44)
                    .padding(.bottom, 4)
            }
        } else {
            valueRow(
                title: "Ollama",
                iconName: "desktopcomputer",
                value: "localhost:11434"
            )
        }
    }

    private func menuRow<MenuContent: View>(
        title: String,
        iconName: String,
        selection: String,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Menu(content: menuContent) {
                HStack(spacing: 5) {
                    Text(selection)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .frame(width: panelWidth, height: 36)
    }

    private var modelPickerRow: some View {
        Button {
            isModelPickerPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(companionManager.selectedModel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .frame(width: panelWidth - 12, height: 36)
            .background(
                isModelPickerPresented ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .frame(width: panelWidth, height: 36)
        .pointerCursor()
        .popover(isPresented: $isModelPickerPresented, arrowEdge: .trailing) {
            modelPickerPopover
        }
    }

    private var modelPickerPopover: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models…", text: $modelSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredModelNames, id: \.self) { modelName in
                        Button {
                            companionManager.setSelectedModel(modelName)
                            isModelPickerPresented = false
                            modelSearchText = ""
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(modelName)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                if modelName == companionManager.selectedModel {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(
                                modelName == companionManager.selectedModel
                                    ? Color.accentColor.opacity(0.75)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 270, height: 340)
    }

    private var filteredModelNames: [String] {
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return companionManager.availableModelNames }
        return companionManager.availableModelNames.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private func valueRow(title: String, iconName: String, value: String) -> some View {
        rowLabel(title: title, iconName: iconName, value: value, showsChevron: false)
    }

    private func rowLabel(title: String, iconName: String, value: String, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private func menuSelectionLabel(_ text: String, isSelected: Bool) -> some View {
        HStack {
            Text(text)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private var localModelsSection: some View {
        VStack(spacing: 0) {
            if shouldShowLocalModelState(localModelState.transcription) {
                modelStatusRow(
                    title: "Parakeet",
                    iconName: "bird.fill",
                    state: localModelState.transcription,
                    prepareAction: companionManager.prepareLocalTranscriptionModel
                )
            }
            if shouldShowLocalModelState(localModelState.voice) {
                modelStatusRow(
                    title: "Kokoro",
                    iconName: "speaker.wave.2",
                    state: localModelState.voice,
                    prepareAction: companionManager.prepareLocalVoiceModel
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var shouldShowAnyLocalModelState: Bool {
        shouldShowLocalModelState(localModelState.transcription)
            || shouldShowLocalModelState(localModelState.voice)
    }

    private func shouldShowLocalModelState(_ state: LocalModelPreparationState) -> Bool {
        switch state {
        case .downloading, .installing, .preparing, .failed:
            return true
        case .notDownloaded, .downloaded, .ready:
            return false
        }
    }

    private func modelStatusRow(
        title: String,
        iconName: String,
        state: LocalModelPreparationState,
        prepareAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                    Circle()
                        .fill(modelStatusColor(state))
                        .frame(width: 7, height: 7)
                    Text(state.displayText)
                        .font(.system(size: 9))
                        .foregroundStyle(modelStatusColor(state))
                }
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
            Spacer()
            if state == .notDownloaded || isFailedModelState(state) {
                Button(action: prepareAction) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Download model")
                .pointerCursor()
            } else if state != .ready && state != .downloaded {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: state.progress == nil ? 34 : 43)
    }

    private func modelStatusColor(_ state: LocalModelPreparationState) -> Color {
        switch state {
        case .ready, .downloaded: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func isFailedModelState(_ state: LocalModelPreparationState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var permissionsSection: some View {
        VStack(spacing: 0) {
            if !companionManager.hasAccessibilityPermission {
                permissionButton(
                    title: "Accessibility",
                    iconName: "hand.raised.fill",
                    action: { _ = WindowPositionManager.requestAccessibilityPermission() }
                )
            }
            if !companionManager.hasScreenRecordingPermission {
                permissionButton(
                    title: "Screen Recording",
                    iconName: "rectangle.dashed.badge.record",
                    action: { _ = WindowPositionManager.requestScreenRecordingPermission() }
                )
            }
            if !companionManager.hasScreenContentPermission {
                permissionButton(
                    title: "Screen Content",
                    iconName: "eye.fill",
                    action: companionManager.requestScreenContentPermission
                )
            }
            if !companionManager.hasMicrophonePermission {
                permissionButton(
                    title: "Microphone",
                    iconName: "mic.fill",
                    action: requestMicrophonePermission
                )
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionButton(title: String, iconName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var actionsSection: some View {
        VStack(spacing: 0) {
            if companionManager.isGuidedSessionActive {
                Button {
                    companionManager.stopGuidedSession()
                } label: {
                    actionRow(title: "Stop Walkthrough", iconName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .pointerCursor()
            }

            updateAction

            Button {
                companionManager.clearConversation()
            } label: {
                actionRow(title: "Clear Conversation", iconName: "trash", showsChevron: true)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                OpenClickyDiagnostics.revealLog()
            } label: {
                actionRow(title: "Open Debug Log", iconName: "doc.text.magnifyingglass", showsChevron: true)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                NSApp.terminate(nil)
            } label: {
                actionRow(title: "Quit OpenClicky", iconName: "power", iconColor: .red)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var updateAction: some View {
        if !updater.isRunningFromApplications {
            Button {
                updater.installCurrentApplication()
            } label: {
                actionRow(title: "Install in Applications", iconName: "square.and.arrow.down", showsChevron: true)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        } else {
            switch updater.state {
            case .available(let build, _):
                Button {
                    updater.installAvailableUpdate()
                } label: {
                    actionRow(title: "Install Update \(build)", iconName: "arrow.down.circle.fill", showsChevron: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .pointerCursor()
            case .checking:
                progressActionRow(title: "Checking for Updates")
            case .downloading:
                progressActionRow(title: "Downloading Update")
            case .installing:
                progressActionRow(title: "Installing Update")
            case .failed:
                Button {
                    updater.checkForUpdates()
                } label: {
                    actionRow(title: "Update Failed — Retry", iconName: "exclamationmark.arrow.triangle.2.circlepath", showsChevron: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .pointerCursor()
            case .idle, .upToDate:
                Button {
                    updater.checkForUpdates()
                } label: {
                    actionRow(title: "Check for Updates", iconName: "arrow.triangle.2.circlepath", showsChevron: true)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func progressActionRow(title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func actionRow(
        title: String,
        iconName: String,
        iconColor: Color = .secondary,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var visibleErrorMessage: String? {
        authenticationManager.authenticationErrorMessage
            ?? companionManager.providerErrorMessage
            ?? companionManager.interactionErrorMessage
            ?? companionManager.buddyDictationManager.lastErrorMessage
    }

    private var statusText: String {
        guard companionManager.isOpenClickyEnabled else { return "Stopped" }
        guard companionManager.visualPromptPermissionsGranted else { return "Needs permission" }
        if companionManager.isWaitingForGuidedAction { return "Waiting for next step" }
        if companionManager.isGuidedSessionActive { return "Guiding" }
        guard companionManager.hasMicrophonePermission else { return "Screenshot ready" }
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Responding"
        }
    }

    private var statusColor: Color {
        guard companionManager.isOpenClickyEnabled else { return .secondary }
        guard companionManager.visualPromptPermissionsGranted else { return .orange }
        switch companionManager.voiceState {
        case .idle: return .green
        case .listening, .processing, .responding: return .accentColor
        }
    }

    private func requestMicrophonePermission() {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authorizationStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private func saveAPIKey() {
        do {
            try companionManager.saveAPIKey(
                apiKeyInput,
                for: companionManager.selectedAIProvider
            )
            apiKeyInput = ""
            apiKeySaveMessage = "Saved in Keychain"
        } catch {
            apiKeySaveMessage = error.localizedDescription
        }
    }
}
