import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var authenticationManager: ChatGPTAuthenticationManager
    @State private var apiKeyInput = ""
    @State private var apiKeySaveMessage: String?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        authenticationManager = companionManager.chatGPTAuthenticationManager
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
        .frame(width: 310)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
                    .frame(width: 34, height: 34)
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenClicky")
                    .font(.system(size: 14, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 12)
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

            menuRow(
                title: "Model",
                iconName: "cpu",
                selection: companionManager.selectedModel
            ) {
                ForEach(companionManager.availableModelNames, id: \.self) { modelName in
                    Button {
                        companionManager.setSelectedModel(modelName)
                    } label: {
                        menuSelectionLabel(
                            modelName,
                            isSelected: companionManager.selectedModel == modelName
                        )
                    }
                }
            }

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
                selection: companionManager.buddyDictationManager.transcriptionProviderDisplayName
            ) {
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

            accountSection

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
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(authenticationManager.accountEmail ?? "ChatGPT")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("Connected")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                }
                .menuStyle(.borderlessButton)
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
        Menu(content: menuContent) {
            rowLabel(title: title, iconName: iconName, value: selection, showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .pointerCursor()
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

            Button {
                companionManager.clearConversation()
            } label: {
                actionRow(title: "Clear Conversation", iconName: "trash")
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                NSApp.terminate(nil)
            } label: {
                actionRow(title: "Quit OpenClicky", iconName: "power")
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 6)
    }

    private func actionRow(title: String, iconName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .frame(height: 36)
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
