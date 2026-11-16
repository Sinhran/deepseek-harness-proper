# Agent profiles (vendored, verbatim)

Upstream: https://github.com/deepseek-ai/deepseek-harness
License: MIT, Copyright (c) 2026 DeepSeek (full text in /THIRD_PARTY_NOTICES.md).
These files keep their MIT license; the rest of this project is Apache-2.0.
Commit: fcc0ad462172522aaf5c93a7b2e01f6b9f0b0159 (master, 2026-11-04)
Files: packages/bundle/web-app/presets/{standard,minimal,ptc,cordis}.patch.yml

These four files are byte-for-byte copies of the official web-app agent
presets. Do not edit them; re-vendor from upstream instead. The app parses
them at launch (Sources/dsh/AgentProfiles.swift) and applies what the
native loop supports: the persona prefix (with {{model}} substituted),
the fs read/write/edit flags, and per-profile tool gating. Rows with no
native equivalent (jobs, goals, ask-user, todo, compaction, executor-ptc,
cordis-specific tools) are reported in Settings, not silently dropped.

    standard  order 1  full coding agent
    ptc       order 2  coding agent, workflow rows disabled, + tool-executor-ptc
    minimal   order 3  shell-only helper, complete persona, no runtime context
    cordis    order 4  coding agent + cordis tooling and preset-authoring skills
