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
