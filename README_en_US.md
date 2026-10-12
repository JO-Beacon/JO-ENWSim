# JO-ENWSim

**Emergent Narrative World Simulator**
No plot. Just causality.

> No plot. Just causality.
> Set the world, drop the opening, let it unfold.

JO-ENWSim is an emergent narrative simulator — a multi-agent causal sandbox. The player controls one character (the player character), while AI drives multiple NPCs. There is no script; the world unfolds purely through causality.

[中文](./README.md)

## Principles

- **Information isolation** — every character has its own data; when AI drives a character, it can only see that character's information.
- **Never feed raw history** — AI only sees structured information extracted from the past, avoiding pattern fixation from long context.
- **The player character gets no special treatment** — it is fully isomorphic to NPCs; the only exception is that its behavior is decided by the player, not by AI.

## How it works

The basic unit is **one behavior by one character = one turn**. Three kinds of agents share a single flow:

| Agent | Role |
|-------|------|
| **God** (AI, omniscient) | Advances the world, selects participating characters, decides who acts next |
| **Character Perception** (one per character, AI) | What that character perceives right now |
| **Character Behavior** (one per character) | How that character acts; NPCs are driven by AI, the player character by the player |

## Naming

| Use | Name |
|-----|------|
| Repository / product | `JO-ENWSim` |
| CLI command | `joenws` |
| Python package | `joenws` |
| npm package | `JO-ENWSim` |

Use `JO-ENWSim` for the product name; use `joenws` or `jo_enws` in code (avoid hyphens and capitals).

## Status

Early design stage; no working code yet.

## License

TBD.
