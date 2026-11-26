<div align="center">

<img src="assets/AppIcon.iconset/icon_256x256.png" height="88" alt="Agent Assistant icon">

<h1>Agent Assistant</h1>

<h3>Select text anywhere on your Mac, then translate it or ask about it.</h3>

<p>A lightweight macOS menu-bar assistant. Answers come from the Claude Code or Codex CLI already signed in on your Mac, with no server and no API key.</p>

[![Version](https://img.shields.io/badge/version-1.0-1f7ae0.svg)](Info.plist)
[![macOS](https://img.shields.io/badge/macOS-13%2B-555555.svg)](#install)
[![Swift](https://img.shields.io/badge/Swift-AppKit_%C2%B7_SwiftUI-F05138.svg)](Sources)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)

**English** · [简体中文](README.zh-CN.md)

[Screenshots](#screenshots) · [Install](#install) · [Usage](#usage) · [Settings](#settings-window) · [Response times](#response-times) · [How it works](#how-it-works) · [Development](#development)

</div>

Select a passage in a web page, a PDF or any other app. **翻译 (Translate)** and **提问 (Ask)** buttons appear next to the pointer. Click one and the **Claude Code** or **Codex** CLI signed in on this Mac answers. You can keep asking follow-up questions in the same panel.

- Native AppKit + SwiftUI. The app is about 3 MB and includes builds for both Apple silicon and Intel. While idle it only listens for mouse events, so it uses almost no resources.
- It calls the command-line tools directly and uses their sign-in and usage limits. No extra service, no API key.
- Your text goes to the selected model only when you click Translate or send a question. Selecting text alone sends nothing.
- The interface is currently in Chinese. Translations can go into Simplified or Traditional Chinese, English, Japanese, Korean, French, German or Spanish.

## Screenshots

**Select text.** Drag over a passage or double-click it. When you release the mouse, **翻译 (Translate)** and **提问 (Ask)** appear below the pointer.

<p align="center"><img src="assets/screenshots/selection.png" width="600" alt="A selected paragraph on a web page with the Translate and Ask buttons below it"></p>

**Translate.** The translation appears in a panel next to the text. You can keep asking follow-up questions below it.

<p align="center"><img src="assets/screenshots/translate.png" width="640" alt="The Agent Assistant panel showing the Chinese translation of the selected paragraph"></p>

**Ask about a PDF.** This works in Chrome's built-in PDF viewer too. Headings, lists, bold text and formulas in the answer are formatted for reading.

<p align="center"><img src="assets/screenshots/pdf-ask.png" width="760" alt="A sentence selected in a PDF in Chrome, with a question about it and the answer in the panel"></p>

## Install

1. You need macOS 13 or later and the Apple Command Line Tools. Run `bash build.sh`. It builds `dist/Agent Assistant.app` for both Apple silicon and Intel.
2. Drag the app to Applications (or `~/Applications`) and open it. A viewfinder icon appears in the menu bar.
3. On first launch the settings window opens. Click **前往授权 (Grant access)**, then turn on Agent Assistant under **System Settings → Privacy & Security → Accessibility**. No restart is needed: the settings page changes to **已允许辅助功能 (Accessibility allowed)** on its own.
4. Install and sign in to at least one CLI: Claude Code (`claude auth login`) or Codex (`codex login`). The check button on the **模型 (Model)** tab confirms it works.

**Why rebuilding does not cost you the permission.** macOS ties the Accessibility permission to the app's code signature. On the first build, `signing.sh` creates a self-signed certificate in `~/.agent-assistant/signing/` and signs every later build with it. The signature stays the same, so the permission stays valid. With an ad-hoc signature (`codesign -s -`), the signature changes on every build. System Settings still shows the switch as on, but the permission no longer works.

## Usage

- **Select text**: drag to select or double-click, then release the mouse. Click **翻译 (Translate)** for an instant translation, or **提问 (Ask)** to type a question first. You can keep asking in the panel. Each request includes the original text and the latest eight questions and answers. **复制回答 (Copy answer)** copies the answer as the model wrote it, Markdown included.
- **When the selection cannot be read**: Chrome's built-in PDF viewer, freshly opened web pages and apps such as Feishu (Lark) do not share the selected text with macOS. The assistant then sends ⌘C to that app once to copy it, and restores your clipboard right afterwards. You can turn this off in settings. It never does this in Finder or in password fields, or when you drag a window or click a button or scroll bar.
- **Services menu**: in apps that support Services, select text and right-click → **Services** → **用 Agent Assistant 翻译 / 提问** (Translate / Ask with Agent Assistant).
- **Clipboard**: press ⌘C first, then choose **翻译剪贴板文字** (Translate clipboard text) or **用剪贴板文字提问…** (Ask about clipboard text) from the menu bar. These two do not need the Accessibility permission.

## Settings window

| Tab | What it contains |
| --- | --- |
| 划词 (Selection) | Whether to show the buttons, permission status, the ⌘C fallback switch, translation language, and the clipboard actions |
| 模型 (Model) | Claude Code or Codex, the model, and the reasoning effort. Codex models that offer it also get a **快速模式 (Fast)** switch. The measured response time for that combination appears right below. A button checks the sign-in status |
| 响应时间 (Response time) | A model × reasoning-effort grid. Each cell is the median of 3 requests, in seconds. Darker green is faster, 额度 (quota) means the usage limit had run out, and a blue border marks the combination in use. **Click a cell to switch to that combination.** The button at the top right tests the current combination. On the Codex page, 标准 / 快速 (Standard / Fast) shows the two speeds separately |

The menu-bar item **响应时间… (Response times…)** opens the third tab directly.

| 划词 (Selection) | 模型 (Model) |
| --- | --- |
| <img src="assets/screenshots/settings-selection.png" alt="Selection tab: show the buttons, Accessibility allowed, Cmd+C fallback, translation language, clipboard actions"> | <img src="assets/screenshots/settings-model.png" alt="Model tab: Claude Code, Sonnet 5.5, default effort, measured response time 3.61 s"> |

<p align="center"><img src="assets/screenshots/settings-latency.png" width="720" alt="Response time tab: a model by reasoning-effort grid of median times in seconds"></p>

## Response times

Measured on 2026-11-26. Each combination translated the fixed sentence `The library opens at nine.` into Simplified Chinese three times in a row. Each time runs from sending the request to receiving the full translation and includes CLI startup. Of 154 combinations, 122 succeeded all three times. The other 32 returned no result because the usage limit had run out: the Codex quota was used up at the time, and Fable was not included in the subscription plan used.

- Sonnet 5.5 was the fastest, with a median of 3.3–3.6 s at every effort level. Haiku 5.5 took about 3.8–5.4 s.
- Most other Claude models took 4–6 s. Most Codex models took 6–9 s.
- Reasoning effort made little difference for translating a short sentence.

**Codex Fast mode.** Codex offers a faster serving tier for its models. Codex describes it per model, for example "1.5x speed" or "2x speed, increased usage", so some models use more quota with it. It speeds up only the model's output, not the few seconds the CLI takes to start, so longer answers gain the most. Measured on 2026-11-27 with GPT-6.2-Sol, a one-sentence translation went from about 5.9 s to 5.4 s, and a 500-character explanation from about 16.5 s to 12.4 s.

The raw data is in [`benchmarks/2026-11-26/results.json`](benchmarks/2026-11-26/results.json) and the spreadsheet in [`benchmarks/2026-11-26/响应时间-全部组合.xlsx`](benchmarks/2026-11-26/响应时间-全部组合.xlsx). These runs went through the local bridge of [Paper_Mind](https://github.com/ZJU-OmniAI/Paper_Mind), and the app's Response time tab reads them too. The bridge also starts the CLI once per request, so the times compare directly.

## How it works

Each request starts the CLI once in a temporary directory, passes the text and conversation on standard input, and deletes the directory afterwards. Clicking **停止 (Stop)** ends the whole process group.

- **Claude Code**: `claude -p --output-format json`, with tools, MCP, slash commands and hooks turned off, and no session saved.
- **Codex**: `codex exec --json --ephemeral`, with a read-only sandbox, the user config ignored, and command execution, web search and multi-agent turned off. With Fast mode on, it adds `-c service_tier="priority"`.
- **Finding the CLI**: it searches PATH, `~/.local/bin`, Homebrew, nvm and the Codex CLI bundled with ChatGPT.app. If it finds several copies, it uses the one with the newest `--version` that actually runs, so an old npm install does not hide newer models.
- **Environment**: an app opened from Finder gets very few environment variables. The assistant reads `PATH` and the proxy settings (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` and their lowercase forms) from your login shell, and nothing else. A proxy that works in Terminal therefore works here too.
- **Model list**: read from the CLIs themselves (Claude's `initialize`, Codex's `app-server model/list`). This starts no conversation and uses no quota.

`AGENT_ASSISTANT_CLAUDE_BIN` and `AGENT_ASSISTANT_CODEX_BIN` set the CLI paths explicitly.

## Development

```
Sources/
  App.swift             Menu bar, selection buttons, chat panel, settings window
  Selection.swift       Global mouse monitor, reading the selection via Accessibility, ⌘C fallback
  AssistantView.swift   Chat panel, conversation session, Markdown answers
  Backend.swift         Calling Claude Code / Codex, error classification, model catalog
  Subprocess.swift      Child processes (own process group), login-shell environment, newest-CLI lookup
  Latency.swift         Response-time tests and records
  ResponseTimeView.swift / SettingsView.swift   Settings window
Tests/                  Backend checks against fake claude / codex CLIs
tools/make-icon.swift   Generates assets/AppIcon.iconset
```

- Tests: `bash Tests/run.sh`. They use two fake CLIs and cover finding the newest version, model catalogs, generation and arguments for both tools, quota and sign-in errors, ending the whole process group on stop, switching models mid-conversation, and response-time records.
- Selection debugging: run `defaults write org.agent-assistant.app debugSelection -bool true`, then `log stream --predicate 'process == "AgentAssistant"'` to see which path each selection took and how long it took. Turn it off afterwards with `defaults delete org.agent-assistant.app debugSelection`.

[Issues](https://github.com/ZJU-OmniAI/Agent_Assistant/issues) and pull requests are welcome.

## License

[MIT](LICENSE). Claude Code, Codex and their services remain subject to their own terms.
