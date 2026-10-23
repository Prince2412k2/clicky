# Third-Party Notices

OpenClicky can download and run optional speech models locally. The model files are not stored in this repository or bundled with the application.

## FluidAudio

- Project: https://github.com/FluidInference/FluidAudio
- License: Apache License 2.0
- Purpose: Native Swift/Core ML runtime and verified model downloading for local speech recognition and synthesis.

## NVIDIA Parakeet Realtime EOU 120M

- Model: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
- Upstream model family: NVIDIA Parakeet
- License: CC BY 4.0
- Attribution: NVIDIA Corporation and the Parakeet model authors.
- Purpose: On-device streaming English speech recognition and end-of-utterance detection.

## Kokoro-82M

- Model: https://huggingface.co/hexgrad/Kokoro-82M
- Core ML conversion: https://huggingface.co/FluidInference/kokoro-82m-coreml
- License: Apache License 2.0
- Purpose: On-device text-to-speech synthesis.

The complete license texts and additional transitive notices are available in the linked upstream repositories and in FluidAudio's `LICENSE` and `ThirdPartyLicenses` directories.

## Peekaboo and AXorcist

- Peekaboo: https://github.com/openclaw/Peekaboo
- AXorcist: https://github.com/openclaw/AXorcist
- License: MIT
- Copyright: Peter Steinberger and contributors
- Purpose: In-process semantic macOS Accessibility inspection and automation. OpenClicky links only the reusable automation library and does not embed Peekaboo's agent runtime, model providers, MCP server, CLI, or user interface.
