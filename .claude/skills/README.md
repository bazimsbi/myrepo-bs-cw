# Project skills

This folder vendors the skills from
[ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills)
so they load automatically in **every** Claude Code session that clones this repo
(project-scoped skills under `.claude/skills/` are picked up on session start).

## Contents

The **28 featured skills** from the catalog — e.g. `artifacts-builder`,
`brand-guidelines`, `canvas-design`, `mcp-builder`, `webapp-testing`,
`theme-factory`, `content-research-writer`, `tailored-resume-generator`,
`slack-gif-creator`, `video-downloader`, `invoice-organizer`.

The 832 `*-automation` app skills (driven by the Rube MCP / Composio server)
are intentionally **not** vendored here: they require network access to
Composio's MCP endpoint, which is unavailable in network-restricted
environments. Add individual ones from the upstream repo if you need them.

`acs-skill-creator` is prefixed to avoid colliding with the built-in
`skill-creator`.

## Invocation

They trigger automatically when relevant, or invoke by name, e.g.
`/webapp-testing`, `/canvas-design`, `/mcp-builder`.

Source: https://github.com/ComposioHQ/awesome-claude-skills

---

## OpenMontage skills (48)

Vendored from [calesthio/OpenMontage](https://github.com/calesthio/OpenMontage)
(AGPLv3 — note this license if any of this code is ever redistributed or used
to power a hosted service). Only the `.claude/skills/` knowledge/reference
skills were taken; the Python pipeline app, Remotion composer, and Node
tooling were **not** vendored.

**Work offline, no API key or network needed:**
`ffmpeg`, `video-edit`, `video-download` (yt-dlp), `video-understand` (local
Whisper), `remotion`, `remotion-best-practices`, `manim-composer`,
`manimce-best-practices`, `manimgl-best-practices`, `d3-viz`,
`beautiful-mermaid`, `framer-motion`, `lottie-bodymovin`, `threejs-*` (8
skills), `tailwind-design-system`, `web-design-guidelines`,
`vercel-composition-patterns`, `vercel-react-best-practices`, `visual-style`,
`playwright-recording` (local browser only).

**Need a paid provider API key + outbound network** (blocked in
network-restricted environments — same constraint as the Composio/21st.dev
skills above): `elevenlabs`, `music`, `sound-effects`, `speech-to-text`,
`text-to-speech`, `agents`, `setup-api-key`, `heygen` (deprecated —
superseded by `create-video`/`avatar-video`), `create-video`, `avatar-video`,
`faceswap`, `video-translate`, `ai-video-gen`, `ltx2`, `bfl-api`,
`flux-best-practices`, `acestep`, `azure-speech-to-text`, `video_toolkit`.

## Invocation

They trigger automatically when relevant, or invoke by name, e.g.
`/ffmpeg`, `/video-edit`, `/manim-composer`, `/threejs-fundamentals`.

Source: https://github.com/calesthio/OpenMontage
