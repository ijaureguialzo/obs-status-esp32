# AGENTS.md — Central Access Point for AI Agents

This file is the **single entry point** for AI agents (Claude Code, Codex, Gemini CLI, opencode, Cursor, Windsurf, …) working in the **`obs-status-esp32`** repository.

It defines how agents operate in this repository: the rules, the workflow, the verification gates and the commit protocol. It is intentionally concise and operational.

For **what** to build, read the component specs in [`specs/`](specs/). For **what** to build next, check [`PLAN.md`](PLAN.md). For **how** to work, follow [Spec 06 — AI Agentic Workflow](specs/06-agentic/AGENT_SPEC.md).

## 1. Project Overview

`obs-status-esp32` is a two-part system that monitors OBS Studio recording state and drives a physical indicator:

1. **macOS app** (`macos-app/`): SwiftUI app (Swift 6 language mode, SwiftPM package + Xcode project, SwiftUI, `@Observable`) that connects to OBS Studio through the WebSocket v5 API and forwards recording/scene state to an ESP32 over USB CDC (IOKit-based serial).
2. **ESP32 firmware** (`esp32-firmware/`): C firmware (ESP-IDF via PlatformIO) that receives text commands over USB CDC and drives either an onboard WS2812 RGB LED (`esp32-s3-dev-kit-n8r8`) or a Waveshare ESP32-C6-Touch-LCD-1.47 touch LCD (`esp32-c6-touch-lcd-1_47`).

The transport is a **text-based protocol over USB CDC** (115200 baud, 8N1, LF line endings, UTF-8). Source of truth: `protocol/obs_protocol.h` (C) ↔ `macos-app/obs-status-macos-ui/Models/ObsProtocol.swift` (Swift), enforced by `scripts/check_protocol_sync.sh`.

Supported boards:

| Board | PlatformIO env | Indicator |
|-------|----------------|-----------|
| ESP32-S3-DevKit N8R8 (default) | `esp32-s3-dev-kit-n8r8` | Onboard WS2812 RGB LED |
| Waveshare ESP32-C6-Touch-LCD-1.47 | `esp32-c6-touch-lcd-1_47` | 172x320 JD9853 touch LCD (scene name + color background + tap-to-pause) |

## 2. Rules

These rules are **normative** and take precedence over anything else in this file when they conflict.

1. **Conventional Commits** — every commit must follow [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<optional scope>): <subject>`, where type ∈ {`feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`, `perf`, `chore`}.
2. **Co-author trailer** — every commit must end with the co-author trailer of the LLM that performed the work, e.g. `Co-authored-by: opencode <opencode@assistant.dev>` (substitute the working LLM's own trailer for other agents).
3. **Commit on task completion** — always create the commit when a task is completed.

## 3. Repository Layout

```
obs-status-esp32/
├── AGENTS.md                     # Central access point for agents (this file)
├── PLAN.md                       # Improvement backlog / task list
├── README.md                     # Project overview & quick start
├── LICENSE
├── version.txt                   # Semver source of truth (version + build)
├── Makefile                      # Build / check shortcuts
├── protocol/
│   └── obs_protocol.h            # Shared protocol definitions (C source of truth)
├── specs/                        # SDD component specs
│   ├── 01-overview/
│   ├── 02-protocol/
│   ├── 03-macos-app/
│   ├── 04-esp32-firmware/
│   ├── 05-deployment/
│   └── 06-agentic/              # AI agentic workflow spec
├── scripts/
│   ├── check_protocol_sync.sh   # C <-> Swift protocol drift check
│   └── generate_version.sh      # version.txt -> generated headers / plist
├── macos-app/                    # SwiftUI macOS app (SwiftPM package + Xcode project)
│   ├── Package.swift
│   ├── .swift-format
│   ├── obs-status-macos-ui/     # Swift sources
│   ├── Tests/ObsStatusTests/    # Swift tests
│   └── obs-status-macos-ui.xcodeproj/
└── esp32-firmware/               # ESP32 firmware (ESP-IDF via PlatformIO)
    ├── platformio.ini
    ├── sdkconfig.defaults
    ├── boards/
    ├── components/               # Vendored Waveshare drivers
    ├── include/
    ├── src/
    └── scripts/
```

## 4. Specs Index

| # | Spec | Path | Topic |
|---|------|------|-------|
| 01 | [PROJECT_SPEC.md](specs/01-overview/PROJECT_SPEC.md) | `specs/01-overview/` | Project overview & architecture |
| 02 | [PROTOCOL_SPEC.md](specs/02-protocol/PROTOCOL_SPEC.md) | `specs/02-protocol/` | Communication protocol |
| 03 | [APP_SPEC.md](specs/03-macos-app/APP_SPEC.md) | `specs/03-macos-app/` | macOS app requirements |
| 04 | [FIRMWARE_SPEC.md](specs/04-esp32-firmware/FIRMWARE_SPEC.md) | `specs/04-esp32-firmware/` | ESP32 firmware requirements |
| 05 | [DEPLOYMENT_SPEC.md](specs/05-deployment/DEPLOYMENT_SPEC.md) | `specs/05-deployment/` | Build & distribution |
| 06 | [AGENT_SPEC.md](specs/06-agentic/AGENT_SPEC.md) | `specs/06-agentic/` | **AI agentic workflow (SDD)** |

## 5. Commands and Verification Gates

Run from the repository root unless stated otherwise.

### 5.1 Protocol sync (C <-> Swift)

```bash
bash scripts/check_protocol_sync.sh
```

### 5.2 Firmware

```bash
pio test -d esp32-firmware -e host-tests                      # Unity host tests (protocol modules)
pio run -d esp32-firmware -e esp32-s3-dev-kit-n8r8          # Build ESP32-S3 (onboard LED)
pio run -d esp32-firmware -e esp32-c6-touch-lcd-1_47        # Build C6 touch LCD
```

### 5.3 macOS app

```bash
swift build --package-path macos-app
swift test --package-path macos-app
cd macos-app && swift-format lint --strict --recursive obs-status-macos-ui Tests
cd macos-app && xcodebuild -scheme obs-status-macos-ui -configuration Debug build
```

CI additionally builds the Swift package with `SWIFT_TREAT_WARNINGS_AS_ERRORS=1`.

### 5.4 Make shortcuts

```bash
make check      # protocol sync + firmware host tests + Swift tests
make check-all  # check + full firmware builds + Xcode build
```

### 5.5 Expected results

- Protocol sync: exit 0, "Protocol definitions in sync".
- Firmware host tests: all pass (Unity; dependency-free modules: `protocol_message`, `protocol_line_buffer`, `display_text`).
- Firmware builds: OK for both `esp32-s3-dev-kit-n8r8` and `esp32-c6-touch-lcd-1_47` (plus debug env as needed).
- Swift build: OK, **no warnings** (`SWIFT_TREAT_WARNINGS_AS_ERRORS=1`).
- Swift tests: all pass.
- `swift-format lint --strict`: clean.

## 6. SDD Workflow for Agents

When working on the project, follow this workflow (normatively specified in [Spec 06](specs/06-agentic/AGENT_SPEC.md)):

1. **Context**: read this file, the relevant component spec(s) (`specs/01-*` … `specs/05-*`) and `PLAN.md` when tasks are pending.
2. **Specify**: ensure the requirement is captured in the specs. New features MUST get a new or updated spec under `specs/` before implementation. Bugfixes that change observable behavior MUST update the relevant spec.
3. **Plan**: break the work into self-contained tasks: objective, files, concrete steps, acceptance criteria, verification commands.
4. **Implement**: follow the existing architecture and conventions; add tests for new behavior.
5. **Verify**: run all gates (section 5); fix until green.
6. **Document**: update specs, `PLAN.md` and README when behavior or structure change.
7. **Commit**: create the commit(s) for the completed task(s).

## 7. Definition of Done

A task is **done** when all of the following hold:

- [ ] Acceptance criteria are met.
- [ ] All verification gates pass (section 5).
- [ ] Tests were added/updated for new behavior.
- [ ] Relevant spec and docs were updated.
- [ ] The commit(s) were created following Conventional Commits **with the co-author trailer** of the working LLM.

## 8. Commit Protocol

- Conventional Commits: `<type>(<optional scope>): <subject>`, e.g. `feat(macos): add button to forget trusted ESP32 devices`.
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`, `perf`, `chore`.
- One task = one commit (or a few grouped by task).
- **Every commit must end with the co-author trailer of the LLM performing the work**:

  ```
  Co-authored-by: opencode <opencode@assistant.dev>
  ```

- Always create the commit when a task is completed.

## 9. Conventions and Boundaries

- **Protocol changes**: update `protocol/obs_protocol.h`, `macos-app/.../Models/ObsProtocol.swift`, `specs/02-protocol/PROTOCOL_SPEC.md`, firmware parser and tests together; must pass `bash scripts/check_protocol_sync.sh`.
- **Generated files**: never hand-edit `esp32-firmware/include/firmware_version_generated.h` (gitignored) or generated version sources; use `version.txt` + `scripts/generate_version.sh`.
- **Swift**: follow `macos-app/.swift-format`; builds must be warning-free (`SWIFT_TREAT_WARNINGS_AS_ERRORS=1`); format lint runs with `--strict` in CI.
- **Versioning**: `version.txt` is the single source of truth (semver + build number) for both macOS app and firmware.

## 10. Escalation

If a verification gate cannot be satisfied after reasonable attempts, stop and report the status to the human maintainer instead of silently weakening the gates or skipping checks.
