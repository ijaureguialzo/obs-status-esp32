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
2. **Specify**: ensure the requirement is captured in the specs. New or changed observable behavior must update the relevant spec before or alongside implementation.
3. **Plan**: break the work into self-contained tasks: objective, files, concrete steps, acceptance criteria, verification commands.
4. **Implement**: follow the existing architecture and conventions; add tests for new behavior.
5. **Verify**: run all gates (section 5); fix until green.
6. **Document**: update specs, `PLAN.md` and README when behavior or structure changes.
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

---

Now the spec file: `specs/06-agentic/AGENT_SPEC.md`.

Let me compose it fully now.</think>Ahora creo el spec completo para agentes IA siguiendo SDD:<tool_call>write<arg_key>content</arg_key><arg_value># Spec 06: AI Agentic Workflow

## 1. Purpose and Problem Statement

The `obs-status-esp32` repository already carries a complete set of component
specifications (Specs 01–05) and a minimal agent entry file ([`AGENTS.md`](../../AGENTS.md)).
However, there is **no single normative specification** describing **how AI agents
must work** in this repository following Spec-Driven Development (SDD).

An agent working in this repository must be able to answer, without guessing:

1. Which documents it must read before acting (entry point, specs, plan).
2. In which order it must work (SDD phases).
3. What constitutes a completed task (definition of done).
4. Which verification commands must pass before committing.
5. How commits must be written (Conventional Commits + co-author trailer).

Today these rules are scattered across a minimal `AGENTS.md`, the component
specs and the ad-hoc `PLAN.md`, which leads to inconsistent agent behavior
across sessions and agent implementations.

## 2. Solution

Introduce a complete agent operating specification plus a single central
access point:

- [`AGENTS.md`](../../AGENTS.md) — **central access point** for AI agents: project
  overview, normative rules, repository layout, specs index, verification gates,
  SDD workflow, definition of done and commit protocol.
- **This document** (`specs/06-agentic/AGENT_SPEC.md`) — normative SDD process for
  AI agents working on the project.
- Component specs (`specs/01-overview` … `specs/05-deployment`) — source of truth
  for **what** to build in each component.
- `PLAN.md` — source of truth for the improvement backlog and per-task state.

## 3. Scope

### 3.1 In Scope

- Agent responsibilities and workflow (SDD).
- Task lifecycle and definition of done.
- Quality gates that must pass before any commit.
- Commit policy (Conventional Commits + co-author trailer).
- Spec maintenance obligations for agents.

### 3.2 Out of Scope

- Product requirements (covered by Specs 01–05).
- Human decision-making and release management (covered by Spec 05).

## 4. Normative Requirements

### 4.1 Requirement R1 — Central access point

The repository MUST keep an `AGENTS.md` at the repository root that serves as the
central access point for AI agents working on the project. It MUST cover, at
minimum:

- Project overview and supported boards.
- Normative operating rules (commits, co-author trailer, commit timing).
- Repository layout.
- Index of the specs.
- Verification commands and expected results.
- SDD workflow summary.
- Definition of done.
- Commit protocol.

### 4.2 Requirement R2 — SDD workflow

The agent workflow MUST follow Spec-Driven Development:

```
context → specify → plan → implement → verify → document → commit
```

### 4.3 Requirement R3 — Commit policy on task completion

**Requirement**: Whenever a feature or task is completed, the agent MUST
generate the necessary commit(s) following **Conventional Commits** and MUST
always include the **co-author trailer of the LLM that is performing the work**.

- Commit message format: `<type>(<optional scope>): <subject>`.
- Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`,
  `perf`, `chore`.
- Co-author trailer format (opencode): `Co-authored-by: opencode <opencode@assistant.dev>`.
  When a different LLM performs the work, that LLM's own co-author trailer MUST be
  used instead.

### 4.4 Requirement R4 — Quality gates

Before any commit that completes a task, ALL of the following gates MUST pass:

| # | Gate | Command | Expected |
|---|------|---------|----------|
| 1 | Protocol sync (C ↔ Swift) | `bash scripts/check_protocol_sync.sh` | Exit 0, "Protocol definitions in sync" |
| 2 | Firmware host tests | `pio test -d esp32-firmware -e host-tests` | All pass (Unity) |
| 3 | Firmware builds | `pio run -d esp32-firmware -e <env>` | OK (both `esp32-s3-dev-kit-n8r8` and `esp32-c6-touch-lcd-1_47`) |
| 4 | Swift build | `swift build --package-path macos-app` | OK, no warnings (`SWIFT_TREAT_WARNINGS_AS_ERRORS=1`) |
| 5 | Swift tests | `swift test --package-path macos-app` | All pass |
| 6 | Swift format lint | `swift-format lint --strict --recursive obs-status-macos-ui Tests` (in `macos-app/`) | Clean |
| 7 | Xcode build | `xcodebuild -scheme obs-status-macos-ui -configuration Debug build` (in `macos-app/`) | OK |

### 4.5 Requirement R5 — Definition of done

A task is done when: acceptance criteria are met, all quality gates pass, tests
were added/updated for new behavior, relevant specs/docs were updated, and the
commit(s) were created following Conventional Commits with the co-author
trailer.

### 4.6 Requirement R6 — Spec maintenance

Agents MUST update the relevant spec when behavior changes, and MUST update
`PLAN.md` checkboxes / task status accordingly.

## 5. Agent Workflow (normative steps)

### 5.1 Step 0 — Context loading

The agent MUST read, at minimum:

- `AGENTS.md` (this central access point).
- The relevant component spec(s) from `specs/` (01–05).
- `PLAN.md` when there are pending tasks.

### 5.2 Step 1 — Specification phase

Ensure the requirement is captured in the specs. New features MUST get a new or
updated spec under `specs/` before implementation. Bugfixes that change observable
behavior MUST update the relevant spec.

### 5.3 Step 2 — Planning phase

Break the work into self-contained tasks. Each task MUST define: objective,
files, concrete steps, acceptance criteria, verification commands.

### 5.4 Step 3 — Implementation phase

Implement following the existing architecture and conventions; add tests for new
behavior.

### 5.5 Step 4 — Verification phase

Run all quality gates (section 4). Fix until all are green before committing.

### 5.6 Step 5 — Documentation phase

Update specs / `PLAN.md` / README when behavior or structure changed.

### 5.7 Step 6 — Commit phase

When a task is completed, generate the necessary commit(s) following Conventional
Commits and ALWAYS include the co-author trailer of the working LLM.

## 6. Commit Requirements

### 6.1 Conventional Commits

Format: `<type>(<optional scope>): <subject>` with type ∈ {`feat`, `fix`, `docs`,
`style`, `refactor`, `test`, `build`, `perf`, `chore`.

### 6.2 Co-author trailer

Every commit MUST end with the co-author trailer of the LLM performing the work:

```
Co-authored-by: opencode <opencode@assistant.dev>
```

### 6.3 Granularity and timing

One task = one commit (or a few grouped by task). The commit is created when the
task is completed.

## 7. Quality Gates

See section 4 of this spec and [AGENTS.md §5](../../AGENTS.md#5-commands-and-verification-gates).

## 8. Definition of Done

A task is done when all of the following hold:

- Acceptance criteria are met.
- All quality gates pass.
- Tests were added/updated for new behavior.
- Relevant spec and docs were updated.
- Conventional commit(s) were created with the co-author trailer.

## 9. Out of Scope

- Product requirements (Specs 01–05).
- Release management (Spec 05).

## 10. References

- [AGENTS.md](../../AGENTS.md) — central access point for agents.
- [Spec 01 — Project Overview](01-overview/PROJECT_SPEC.md)
- [Spec 02 — Protocol](02-protocol/PROTOCOL_SPEC.md)
- [Spec 03 — macOS App](03-macos-app/APP_SPEC.md)
- [Spec 04 — ESP32 Firmware](04-esp32-firmware/FIRMWARE_SPEC.md)
- [Spec 05 — Deployment](05-deployment/DEPLOYMENT_SPEC.md)
