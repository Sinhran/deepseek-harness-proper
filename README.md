# DeepSeek Harness (Proper)

> **Unofficial community project.** dsh-proper is not made by, affiliated
> with, endorsed by, or sponsored by DeepSeek. "DeepSeek", "DeepSeek
> Harness", and the whale logo belong to their respective rights holders and
> are used here only to describe what this app works with. For the official
> client, see [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness).

Native macOS chat front end for the DeepSeek API agent loop. See PRODUCT.md
and DESIGN.md.

## Build and run

    make run        # build release bundle, sign, and open DSH.app
    make debug      # debug build, run in terminal
    make smoke      # run tests

Tests require a full Xcode install (XCTest is not part of the Command Line
Tools); `swift build` works with the Command Line Tools alone.


## Layout

- `Sources/dsh/` — core (agent loop, tools, plugins, stores)
- `Sources/dsh/UI/` — AppKit interface
- `Sources/dshApp/` — executable entry point
- `Tests/dshTests/` — XCTest suites (Smoke harness plus focused unit tests)
- `Resources/AgentProfiles/` — vendored upstream presets; regenerate the
  embedded fallback with `python3 scripts/vendor-agent-profiles.py`

## Before you use it

DSH runs an AI agent on your Mac with access to a folder you choose and, if
you allow it, your shell. Please read the source before you trust it with
anything that matters. Some things to know:

- Conversations, including file contents the agent changed, are saved
  encrypted (AES-256-GCM) under `~/Library/Application Support/dsh-proper/`.
  The key is kept in your Keychain. If the Keychain item is deleted, those
  conversations can't be recovered. Encryption protects copies and backups
  of the files. It doesn't protect against software running as you, which
  can ask the Keychain for the key. Automations (`automations.json`) are
  not encrypted.
- Shell commands are not sandboxed by the operating system. A command the
  agent runs can read and change anything your user account can. At **Full**
  autonomy the agent, and any enabled plugin, runs shell commands without
  asking; the lower settings ask first.
- Enabling a plugin lets it run any code on your Mac. Only enable plugins you
  have read.
- Commands the agent runs see your environment variables. Variables that
  look like secrets are removed, but anything else is visible to the agent
  and the model provider.
- Your messages and the files the agent reads are sent to the model API you
  configure.
- `web_search` reads DuckDuckGo's HTML results page. It can break if
  DuckDuckGo changes that page or limits requests.

The app is provided as is, without warranty (see LICENSE).

## How this was built

DSH was developed with a set of AI coding agents: Claude Code, Devin, Pi,
Antigravity, and Meta Muse, working under human direction and review. AI
agents make mistakes, including security mistakes that look plausible.
Before building and using the app, we recommend having an agent (or a
person) of your choice review the source for bugs and vulnerabilities. The
code base is small enough to read in full.

## Contributing

Contributions are welcome: bug reports, fixes, reviews, and features. They
are judged on their content alone: whether the change is correct, safe, and
fits the product. Not on who or what wrote it. Human-written,
agent-written, and mixed contributions are treated the same, and the person
submitting is responsible for what they submit.

Please report security problems privately through GitHub's "Report a
vulnerability" (Security tab) rather than in a public issue.

## Acknowledgements

- **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)**
  (MIT, © DeepSeek). The four agent presets and the whale artwork come from
  it, and tool-step titles, result pruning, and conversation branching
  follow its design.
- **Claude desktop app, by Anthropic.** Inspired the window layout: one
  unified top row and direct inspector buttons. No code or assets were
  taken. Not affiliated with Anthropic.
- **DuckDuckGo** powers the `web_search` tool. Not affiliated with Duck Duck
  Go, Inc.
- **Apple's** AppKit and SF Symbols.

Details and full license texts: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Apache License 2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). Material
from DeepSeek Harness stays under its MIT license, as listed in
THIRD_PARTY_NOTICES.md. The license grants no rights to any of the trademarks
named above.
