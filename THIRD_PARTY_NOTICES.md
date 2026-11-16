# Third-party notices

dsh-proper is licensed under the Apache License, Version 2.0 (see `LICENSE`).
It includes the material below, which remains under its own license.

## DeepSeek Harness

- Source: https://github.com/deepseek-ai/deepseek-harness
- License: MIT (full text below)
- Copyright (c) 2026 DeepSeek

Included material:

| File in this repository | Upstream origin |
| --- | --- |
| `Resources/AgentProfiles/standard.patch.yml`, `minimal.patch.yml`, `ptc.patch.yml`, `cordis.patch.yml` | `packages/bundle/web-app/presets/*.patch.yml`, copied verbatim at commit `fcc0ad462172522aaf5c93a7b2e01f6b9f0b0159` |
| `Sources/dsh/AgentProfileYAML.swift` | Generated embedded copies of the four presets above (`scripts/vendor-agent-profiles.py`) |
| `Sources/dsh/UI/BrandMark.swift` (whale path data) | `packages/client/ui-primitives/src/FishLogo.tsx` |

Several behaviors are reimplemented in this project's own code after the
upstream design: tool-result pruning, tool-step titles, and conversation
branching. No upstream source code is copied for those; they are credited
here because the ideas are DeepSeek Harness's.

The DeepSeek name, the DeepSeek Harness name, and the whale artwork are
trademarks or brand assets of their respective rights holders. The MIT
license below covers copyright only; it grants no trademark rights.

```
MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Acknowledgements (no code or assets included)

These are not part of the distributed material and impose no license
obligations. They are credited because this project owes them something.

- **Claude desktop app, by Anthropic.** The window layout is inspired by it:
  one unified top row shared by the traffic lights, sidebar toggle, and
  title, and inspector panels opened by direct buttons at the trailing edge.
  Only the layout idea was taken; no code, icons, or artwork. Claude and
  Anthropic are trademarks of Anthropic, PBC.
- **DeepSeek API.** The app is a client for DeepSeek's public API and links
  to DeepSeek's API documentation and platform site.
- **DuckDuckGo.** The `web_search` tool queries DuckDuckGo's HTML search
  endpoint. DuckDuckGo is a trademark of Duck Duck Go, Inc.
- **Apple.** Built on AppKit; interface icons are SF Symbols, rendered by
  macOS at runtime and used under Apple's terms. No symbol artwork is
  included in this repository.

dsh-proper is not affiliated with, endorsed by, or sponsored by any of the
companies or projects named in this file.
