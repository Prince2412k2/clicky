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

            configurationSection

            if !companionManager.allPermissionsGranted {
                Divider()
                permissionsSection
            }

            Divider()

            shortcutsSection

            Divider()

            footer
        }
        .frame(width: 296)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text("OpenClicky will send your prompts and invoked screenshots directly to OpenAI using your eligible ChatGPT plan. Requests are not stored by OpenClicky.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 30, height: 30)

                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenClicky")
                    .font(.system(size: 13, weight: .semibold))

                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
        .padding(12)
    }

    private var configurationSection: some View {
        VStack(spacing: 4) {
            menuRow(
                title: "Provider",
                iconName: "network",
                selection: companionManager.selectedAIProvider.displayName
            ) {
                ForEach(OpenClickyAIProvider.allCases) { provider in
                    Button(provider.displayName) {
                        apiKeyInput = ""
                        apiKeySaveMessage = nil
                        companionManager.setSelectedAIProvider(provider)
                    }
                }
            }

            menuRow(
                title: "Model",
                iconName: "cpu",
                selection: companionManager.selectedModel
            ) {
                ForEach(companionManager.availableModelNames, id: \.self) { modelName in
                    Button(modelName) {
                        companionManager.setSelectedModel(modelName)
                    }
                }
            }

            menuRow(
                title: "Voice",
                iconName: "waveform",
                selection: companionManager.speechOutput.displayName
            ) {
                ForEach(OpenClickySpeechOutput.allCases) { output in
                    Button(output.displayName) {
                        companionManager.setSpeechOutput(output)
                    }
                }
            }
            menuRow(
                title: "Transcription",
                iconName: "mic",
                selection: companionManager.buddyDictationManager.transcriptionProviderDisplayName
            ) {
                Button("Apple Speech") {
                    companionManager.buddyDictationManager.setTranscriptionProvider(.appleSpeech)
                }
                Button("OpenAI API") {
                    companionManager.buddyDictationManager.setTranscriptionProvider(.openAI)
                }
            }

            accountSection
        }
        .padding(8)
    }

    @ViewBuilder
    private var accountSection: some View {
        if companionManager.selectedAIProvider == .chatGPT {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 17)

                VStack(alignment: .leading, spacing: 1) {
                    Text(authenticationManager.isSignedIn ? "Connected" : "Account")
                        .font(.system(size: 12, weight: .medium))
                    if let accountEmail = authenticationManager.accountEmail {
                        Text(accountEmail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(authenticationManager.isSignedIn ? "Disconnect" : "Connect") {
                    if authenticationManager.isSignedIn {
                        authenticationManager.signOut()
                    } else {
                        authenticationManager.signIn()
                    }
                }
                .controlSize(.small)
                .disabled(authenticationManager.isSigningIn)
                .pointerCursor()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 38)

            if let authenticationErrorMessage = authenticationManager.authenticationErrorMessage {
                Text(authenticationErrorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)

                Button("Try another account or workspace") {
                    authenticationManager.signInWithAnotherAccountOrWorkspace()
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .pointerCursor()
            }
        } else if companionManager.selectedAIProvider.requiresAPIKey {
            HStack(spacing: 8) {
                SecureField(
                    companionManager.hasAPIKey(for: companionManager.selectedAIProvider)
                        ? "Key saved — enter to replace"
                        : "Paste API key",
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

                Button("Save") {
                    saveAPIKey()
                }
                .controlSize(.small)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if let apiKeySaveMessage {
                Text(apiKeySaveMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        } else {
            staticRow(title: "Connection", iconName: "desktopcomputer", value: "localhost:11434")
        }

        if let providerErrorMessage = companionManager.providerErrorMessage {
            Text(providerErrorMessage)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
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
        .pointerCursor()
    }

    private func staticRow(title: String, iconName: String, value: String) -> some View {
        rowLabel(title: title, iconName: iconName, value: value, showsChevron: false)
    }

    private func rowLabel(title: String, iconName: String, value: String, showsChevron: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 17)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("OpenClicky only captures audio and screen content when you use a shortcut.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionButton(
                title: "Microphone",
                isGranted: companionManager.hasMicrophonePermission,
                action: requestMicrophonePermission
            )
            permissionButton(
                title: "Accessibility",
                isGranted: companionManager.hasAccessibilityPermission,
                action: { _ = WindowPositionManager.requestAccessibilityPermission() }
            )
            permissionButton(
                title: "Screen Recording",
                isGranted: companionManager.hasScreenRecordingPermission,
                action: { _ = WindowPositionManager.requestScreenRecordingPermission() }
            )
            permissionButton(
                title: "Screen Content",
                isGranted: companionManager.hasScreenContentPermission,
                action: companionManager.requestScreenContentPermission
            )
        }
        .padding(12)
    }

    private func permissionButton(title: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if !isGranted {
                Button("Grant", action: action)
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .frame(height: 26)
    }

    private var shortcutsSection: some View {
        VStack(spacing: 6) {
            shortcutRow(title: "Voice prompt", keys: "⌃⌥")
            shortcutRow(title: "Screenshot prompt", keys: "⌃⌘")
        }
        .padding(12)
    }

    private func shortcutRow(title: String, keys: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var footer: some View {
        HStack {
            Text("Private by default · No telemetry")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Clear") {
                companionManager.clearConversation()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Clear conversation from memory")
            .pointerCursor()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .pointerCursor()
        }
        .padding(12)
    }

    private var statusText: String {
        guard companionManager.visualPromptPermissionsGranted else { return "Setup required" }
        guard companionManager.hasMicrophonePermission else { return "Screenshot ready" }
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Responding"
        }
    }

    private var statusColor: Color {
        guard companionManager.visualPromptPermissionsGranted else { return .orange }
        guard companionManager.hasMicrophonePermission else { return .yellow }
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
            apiKeySaveMessage = "Saved securely in Keychain"
        } catch {
            apiKeySaveMessage = error.localizedDescription
        }
    }
}
