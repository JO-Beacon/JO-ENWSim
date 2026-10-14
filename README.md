# JO-ENWSim

**Emergent Narrative World Simulator**
No plot. Just causality.

> 不编排剧情，只推演因果。
> 设定世界，投放开场，让它自行展开。

JO-ENWSim 是一个涌现叙事模拟器，一个多 Agent 的因果沙盒。玩家操控一个角色（玩家角色），AI 分别驱动多个 NPC。没有剧本，世界按因果自行展开。

[English](./README_en_US.md)

## 核心原则

- **信息隔离** —— 每个角色有独立的数据，AI 驱动某个角色时只能看到该角色的信息。
- **不喂历史原文** —— AI 只看从历史中提取的结构化信息，消除长上下文导致的模式固化。
- **玩家角色不搞特殊** —— 玩家角色与 NPC 完全同构；唯一特殊处：它的行为由玩家决定，AI 不得代替。

## 如何运作

基本单位：**一个角色的一次行为 = 一回合**。三种 Agent 共用一条流程：

| Agent | 职责 |
|-------|------|
| **上帝**（AI，全知） | 推进世界、框选参与角色、决定下一位行动者 |
| **角色感知**（每角色一个，AI） | 该角色此刻感知到了什么 |
| **角色行为**（每角色一个） | 该角色如何行动；NPC 由 AI 驱动，玩家角色由玩家驱动 |

## 命名

| 用途 | 名称 |
|------|------|
| 仓库 / 产品 | `JO-ENWSim` |
| CLI 命令 | `joenws` |
| Python 包 | `joenws` |
| npm 包 | `JO-ENWSim` |

产品名用 `JO-ENWSim`；代码标识用 `joenws` 或 `jo_enws`（避免连字符与大写）。

## 状态

早期设计阶段，尚无可用代码。

## 许可

[Apache License 2.0](./LICENSE) · Copyright 2026 JO-Beacon

第三方组件（Flutter / Dart / 思源黑体 / 思源宋体）见 [NOTICE](./NOTICE)。

