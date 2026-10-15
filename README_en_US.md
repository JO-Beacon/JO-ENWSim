# JO-ENWSim

**Emergent Narrative World Simulator**
No plot. Just causality.

> Set a world, drop in an opening, let it unfold on its own.

JO-ENWSim is an emergent narrative simulator — a causal sandbox run by multiple agents. The player controls one character; AI drives the others. There is no script. The world unfolds by causality.

[中文](./README.md) · [Apache License 2.0](./LICENSE)

![Workspace](./docs/screenshot.png)

The workspace above: the left rail lists worlds; the middle is the **sequence canvas** (each column is a location, each step is an event, and the lines crossing columns are "moved to another place"); the right panel is the world itself — its setting, opening, characters, memories, and model configuration.

## Status

**The interface is real and usable. The engine is not wired up yet.**

- What works: creating worlds, writing the setting and opening, adding characters, configuring model providers, writing memories, rebinding shortcuts
- What does not: **the world does not actually advance.** Until a model is connected, the canvas shows demo data, and anything typed into the input box never enters the world

Anything in the interface that is not connected yet says so on the spot. It does not pretend otherwise.

## Core principles

- **Information isolation** — every character keeps its own data. When one character is driven, it sees only what that character knows, never what the others do.
- **Never feed raw history** — the whole history is not handed to the model. It gets only what it should know at this moment: the character's own memories, plus what it perceives right now.
- **The player character gets no special treatment** — it is structurally identical to an NPC. The only difference: its actions are decided by the player, and the AI must not decide them instead.

## How it works

The unit is **one character acting once = one turn**. Three kinds of agents share a single flow:

| Agent | Role |
| --- | --- |
| **God** (AI, omniscient) | Advances the world, selects which characters take part, decides who acts next |
| **Perception** (one per character, AI) | What this character perceives right now |
| **Action** (one per character) | How this character acts; NPCs are driven by AI, the player character by the player |

Models can be assigned in layers, from specific to general: **a character's own step → the world default → the global default**.

## Build and run

Requires [Flutter](https://flutter.dev) (stable).

```sh
flutter pub get

# run
flutter run -d windows

# Windows release
scripts/build.ps1            # add -SkipAndroid to skip the Android build
```

Artifacts:

- Windows: `build/windows/x64/runner/Release/joenws.exe`
- Installer (Inno Setup) and split-per-ABI Android APKs: `dist/`

## Naming

| Use | Name |
| --- | --- |
| Product / repository | `JO-ENWSim` |
| Dart package | `joenws` |
| Executable | `joenws.exe` |
| Android application ID | `io.github.jobeacon.joenws` |

The product name is `JO-ENWSim`; code identifiers use `joenws`.

## License

[Apache License 2.0](./LICENSE) · Copyright 2026 JO-Beacon

Third-party components distributed with this project are listed in [NOTICE](./NOTICE):

- Flutter, Dart (BSD-3-Clause)
- Noto Sans SC / Noto Serif SC (SIL OFL 1.1)
- Remix Icon (Remix Icon License v1.0)

The full text of each license lives in [`assets/licenses/`](./assets/licenses), and can also be read inside the app: **Settings → About → View open-source licenses**.
