# NawNo

A native macOS app for running open-source large language models locally. Built with SwiftUI and [MLX](https://github.com/ml-explore/mlx-swift), NawNo keeps your conversations private by running inference entirely on your Mac.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-GPLv3-blue)

## Features

- **Local inference** -- All models run on-device using Apple's MLX framework. Nothing leaves your Mac.
- **Dual backends** -- Native Swift backend for speed, with a Python (mlx-lm) fallback for broader model support.
- **HuggingFace downloads** -- Download quantized models directly from HuggingFace repos.
- **Drag & drop import** -- Add local model folders with drag and drop or the file picker.
- **Streaming chat** -- Real-time token streaming with generation stats (tokens/sec, time-to-first-token).
- **Markdown rendering** -- Responses render with headers, bold, italic, code blocks, and bullet lists.
- **Chat persistence** -- Conversations are saved per-model and persist across sessions.
- **Per-model settings** -- Configure system prompt, temperature, top-k/top-p, context window, repetition penalty, and more for each model independently.
- **Update notifications** -- In-app checks for app updates, MLX Swift updates, and Python mlx-lm updates.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac (Apple Silicon recommended for performance)
- 16 GB+ RAM recommended for larger models

### To build from source

- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Installation

Download the latest `.zip` from the [Releases](../../releases) page, unzip, and drag **NawNo.app** to your Applications folder.

## Building from Source

```bash
# Clone the repo
git clone https://github.com/mjsxi/Nawno.git
cd nawno

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open NawNo.xcodeproj
```

Then build and run with **Cmd+R** in Xcode, or archive for a release build (see below).

## Getting Started

1. Launch NawNo.
2. Click the **+** button in the sidebar to download a model from HuggingFace or import a local model folder.
3. Select a model and click **Load** to load it into memory.
4. Start chatting.

## How It Works

NawNo supports two inference backends:

| Backend | How it works | Best for |
|---------|-------------|----------|
| **Swift** | Direct MLX Swift integration via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-examples) | Fast inference, 2-8 bit quantized models |
| **Python** | Manages an isolated Python venv with [mlx-lm](https://github.com/ml-explore/mlx-examples) | Models not yet supported by the Swift backend |

By default, NawNo uses **Auto** mode -- it tries the Swift backend first and falls back to Python if needed. You can override this per-model in settings.

## Data Storage

All data stays on your Mac:

- **Models**: Stored in the directory you imported them from, or downloaded to `~/Library/Application Support/NawNo/Models/`
- **Chats**: `~/Library/Application Support/NawNo/Chats/`
- **Settings**: `~/Library/Application Support/NawNo/`

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
