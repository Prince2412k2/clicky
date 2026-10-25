# OpenClicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Privacy-first macOS menu bar companion app. Control+Option provides push-to-talk with screen context. Control+Command freezes the pointer's display and opens a focused launcher with drawing tools. Provider keys and OAuth credentials stay in macOS Keychain; there is no telemetry or mandatory proxy.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: ChatGPT Plan, OpenAI API, Anthropic API, Gemini API, or local Ollama
- **Speech-to-Text**: FluidAudio Parakeet EOU 120M is the local default; Apple Speech and OpenAI API transcription are optional fallbacks
- **Text-to-Speech**: FluidAudio Kokoro-82M CoreML is the local default; macOS voice and text-only output are fallbacks
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+); prompts capture only the display containing the pointer
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The selected model embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Teaching Annotations**: Provider-independent `[DRAW:...]` tags render temporary click-through arrows, boxes, highlights, pointers, and labels over the relevant screen or window.
- **Guided Walkthroughs**: `[GUIDE:continue]` starts a bounded live session. OpenClicky observes the user's next click, waits for the app to update, captures the pointer's display, and asks the selected model for one next step. Escape, the menu action, or `[GUIDE:done]` stops the session.
- **Computer Actions**: `[ACTION:click:x,y:label]` requests one visible click only after explicit user intent. A native approval card offers Allow Once, Allow Walkthrough, or Cancel. No typing or consequential action support.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Privacy**: No telemetry, email collection, automatic login item, creator service, or mandatory proxy

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Provider credentials**: API keys and ChatGPT OAuth credentials are stored in Keychain. ChatGPT uses OpenAI's official dynamic-registration flow and public Responses API. Other providers use documented API-key endpoints; Ollama stays on loopback.

**Local speech models**: FluidAudio is pinned to `0.17.7`. Parakeet EOU uses 320 ms chunks and Kokoro uses v3 on macOS 15+ with the legacy runtime on macOS 14. Models download on first use, stay outside the app bundle, remain warm between interactions, and unload when the master switch turns off or the app exits.

**Alpha updates**: GitHub Actions publishes versioned prereleases with `CFBundleVersion` set from the run number. Releases require a persistent Apple signing identity from team `9889PDGCJW`; CI refuses ad-hoc publication and verifies the resulting TeamIdentifier. `OpenClickyUpdater` rejects bundles from other teams, discovers newer prereleases, and installs to `/Applications/OpenClicky.app`.

**Dual build paths**: The Xcode project remains the canonical IDE and CI project. `Package.swift` points at the same app sources for lightweight local development with Command Line Tools. `scripts/dev` downloads pinned dependency snapshots, builds incrementally with SwiftPM, packages a native app bundle, signs with the stable Apple Development identity, and relaunches from `.build/OpenClicky.app`.

**Visual prompt launcher**: Control+Command freezes the current display at native resolution under a borderless full-screen layer while a smaller image is retained for model input. A Spotlight-style field receives focus immediately, the model infers whether to answer, guide, or request an approved action, and drawing controls stay collapsed until requested. Escape closes the complete launcher from any state.

**Bounded guidance**: Guided walkthroughs observe target-app clicks, keyboard input, and scrolling, debounce for 1.2 seconds of UI settling, compare fresh semantic fingerprints, and stop after fifteen steps unless ended earlier. Synthetic clicks require explicit approval; walkthrough-wide approval is reset when the walkthrough stops.

**Computer-use safety**: Semantic element clicks are preferred and coordinate clicks are fallback-only. The selected model is instructed never to request clicks for purchases, deletion, authentication, permissions, financial actions, or sending messages. Approval remains the enforcement boundary; typing and keyboard actions are intentionally unsupported.

**Semantic automation migration**: PeekabooAutomationKit is pinned to `4.9.6` and linked in-process so automation uses OpenClicky's TCC identity. CI selects Xcode 26.3 for Swift 6.2 package compatibility while retaining the macOS 14.2 deployment target. Do not invoke Peekaboo, axcli, cliclick, Node MCP servers, or Hammerspoon as helper processes.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~50 | Menu bar app entry point and companion lifecycle. |
| `CompanionManager.swift` | ~750 | Central state machine for providers, shortcuts, capture, AI responses, local voice, and overlays. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~350 | Compact native provider, model, voice, transcription, account, permission, and quit controls. |
| `OverlayWindow.swift` | ~700 | Full-screen transparent cursor, response, waveform, spinner, and pointing overlay. |
| `CompanionScreenCaptureUtility.swift` | ~120 | Pointer-display capture using ScreenCaptureKit. |
| `ScreenshotPromptWindow.swift` | ~650 | Native-resolution frozen-display launcher with focused input and collapsible annotation tools. |
| `ScreenAnnotation.swift` | ~230 | Drawing-tag parser and click-through teaching overlay for arrows, boxes, highlights, pointers, and labels. |
| `GuidedSession.swift` | ~35 | Parser for provider-independent guided-session continuation and completion tags. |
| `ComputerAction.swift` | ~250 | Click-action parser, coordinate conversion, native approval card, and approved click executor. |
| `SemanticAutomationService.swift` | ~100 | In-process Peekaboo semantic snapshots, compact element descriptions, state fingerprints, and exact element clicks. |
| `ChatGPTAuthenticationManager.swift` | ~650 | ChatGPT OAuth registration, PKCE, ID-token verification, Keychain storage, refresh, recovery, and revocation. |
| `OpenAIResponsesAPI.swift` | ~180 | ChatGPT-plan model discovery and streaming public Responses API client. |
| `OpenClickyServices.swift` | ~430 | Provider definitions, secure API-key storage, model discovery, and direct OpenAI/Anthropic/Gemini/Ollama clients. |
| `SystemTTSClient.swift` | ~30 | Local speech output through macOS AVSpeechSynthesizer. |
| `LocalParakeetTranscriptionProvider.swift` | ~190 | Lazy, shared Parakeet EOU streaming transcription provider with ordered audio processing. |
| `LocalKokoroTTSClient.swift` | ~80 | Lazy Kokoro CoreML initialization, local synthesis, playback, and model cleanup. |
| `LocalSpeechModelState.swift` | ~90 | Shared download, compilation, ready, unloaded, and failure state for local speech models. |
| `OpenClickyUpdater.swift` | ~250 | GitHub prerelease discovery, download validation, `/Applications` installation, and relaunch. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~90 | Protocol and runtime-selectable Apple Speech/OpenAI transcription factory. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `Package.swift` | ~75 | Parallel SwiftPM app and test manifest for lightweight local builds. |
| `scripts/build-local` | ~125 | Builds, bundles, resources, and signs a native app without Xcode. |
| `scripts/dev` | ~15 | Rebuilds and relaunches the fixed-path development app. |

## Build & Run

```bash
# Lightweight local build using Command Line Tools only
./scripts/dev

# Build and sign without launching
./scripts/build-local

# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

The SwiftPM development path downloads pinned dependency snapshots into `.build/local-packages`, incrementally builds the executable, creates `.build/OpenClicky.app`, and signs it with team `9889PDGCJW`. Keep this bundle path and signing identity stable to preserve TCC permissions.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
