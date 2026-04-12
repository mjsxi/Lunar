# Lunar

A native Apple app for running open-source large language models locally. Built with SwiftUI and [MLX](https://github.com/ml-explore/mlx-swift), Lunar keeps your conversations private by running inference entirely on your device.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![iOS 26+](https://img.shields.io/badge/iOS-26%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-blue)
![License](https://img.shields.io/badge/license-GPLv3-blue)

<p align="center">
  <img src="img4git/lunar-app-img.jpg" alt="Lunar app screenshot" width="700">
</p>

## Features

- **Local inference** -- All models run on-device using Apple's MLX framework. Nothing leaves your device.
- **Dual backends** -- Native Swift backend for speed, with a Python (mlx-lm) fallback for broader model support (macOS only).
- **Curated model catalog** -- Suggested models organized by RAM tier so you always pick one that fits your hardware.
- **HuggingFace downloads** -- Download quantized models directly from HuggingFace repos.
- **Streaming chat** -- Real-time token streaming with generation stats (tokens/sec, time-to-first-token).
- **Thinking support** -- Reasoning models display collapsible thinking steps with timing.
- **Chat persistence** -- Conversations are stored with SwiftData and persist across sessions.
- **Universal system prompt** -- Set a default system prompt that applies to all models.
- **Per-model settings** -- Configure temperature, top-p, max tokens, repetition penalty, and more for each model independently.
- **Appearance customization** -- Choose your accent color and color scheme.
- **Siri & Shortcuts** -- Start chats via Apple Shortcuts and Siri integration.
- **Cross-platform** -- Runs on macOS, iOS, and iPadOS.

## Requirements

- macOS 26 or later / iOS 26 or later
- Apple Silicon recommended for performance
- 8 GB+ RAM minimum; 16 GB+ recommended for larger models

### To build from source

- Xcode 16.0+

## Installation

Download the latest `.zip` from the [Releases](../../releases) page, unzip, and drag **Lunar.app** to your Applications folder.

## Building from Source

```bash
# Clone the repo
git clone https://github.com/mjsxi/Lunar.git
cd Lunar

# Open in Xcode
open Lunar.xcodeproj
```

Then build and run with **Cmd+R** in Xcode.

## Getting Started

1. Launch Lunar.
2. Complete the onboarding flow and install a suggested model, or add one manually from HuggingFace.
3. Select a model and start chatting.

## How It Works

Lunar supports two inference backends:

| Backend | How it works | Best for |
|---------|-------------|----------|
| **Swift** | Direct MLX Swift integration via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-examples) | Fast inference, 2-8 bit quantized models |
| **Python** | Manages an isolated Python venv with [mlx-lm](https://github.com/ml-explore/mlx-examples) (macOS only) | Models not yet supported by the Swift backend |

By default, Lunar uses the Swift backend and falls back to Python if needed. You can override this per-model in settings.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
