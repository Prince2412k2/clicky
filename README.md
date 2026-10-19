# OpenClicky

OpenClicky is a privacy-first, open-source macOS AI companion. It lives in the menu bar, accepts voice or annotated screenshot prompts, can see only the content you invoke it on, and can point to relevant interface elements in its response.

Model responses can draw temporary click-through teaching overlays directly on the desktop: animated arrows, boxes, highlights, pulsing pointers, and short labels. The drawings never modify the underlying app and disappear automatically.

OpenClicky is based on the original [Clicky](https://github.com/farzaa/clicky) project and remains available under its MIT license.

## Principles

- No telemetry, analytics, email capture, or creator-owned services
- No automatic launch-at-login registration
- Provider credentials are stored in macOS Keychain
- ChatGPT OAuth tokens go directly between the app, OpenAI authentication, and the public OpenAI API
- Screenshots are captured only when a prompt shortcut is invoked. Voice and visual prompts capture only the display containing the pointer.
- Local-first defaults: Apple Speech, macOS voice, and optional Ollama

## Shortcuts

| Shortcut | Action |
|---|---|
| `Control + Option` | Hold to speak; release to submit with screen context |
| `Control + Command` | Freeze the current display, type a prompt, or mark it with pen, arrow, rectangle, ellipse, and eraser tools |

## AI providers

- **ChatGPT Plan** — official Sign in with ChatGPT flow for eligible Plus or Pro accounts
- **OpenAI API** — API key stored in Keychain
- **Anthropic API** — API key stored in Keychain
- **Gemini API** — API key stored in Keychain
- **Ollama** — local server at `http://127.0.0.1:11434`

Only ChatGPT offers an official third-party subscription-sharing flow in this provider set. OpenClicky does not imitate proprietary clients or reuse unsupported subscription credentials for Anthropic, Gemini, or other providers.

## Speech

- Transcription: Apple Speech by default, with OpenAI API transcription as an option
- Output: macOS voice or text only

## Build

Requirements:

- macOS 14.2 or later
- Xcode 15 or later

```bash
open leanring-buddy.xcodeproj
```

Select the `leanring-buddy` scheme, choose your own signing team, and run with **Command + R**. The built product is named `OpenClicky.app`.

OpenClicky requests microphone, Speech Recognition, Accessibility, and Screen Recording permissions as needed. macOS may require restarting the app after Screen Recording permission changes.

## ChatGPT Plan eligibility

OpenClicky follows OpenAI's documented dynamic-registration, PKCE, token validation, refresh, and public Responses API flow. OpenAI decides eligibility for the account and workspace before issuing plan-sharing permission. If OpenAI reports that a required permission is unavailable, verify that the exact browser account and selected workspace have an eligible Plus or Pro plan, try another account/workspace, or select an API-key/local provider.

## License

MIT. See [`LICENSE`](LICENSE). The original copyright notice is retained as required.
