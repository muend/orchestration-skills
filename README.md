# orchestration-skills

A skill set for **Claude Code** that turns one Claude session into an orchestrator over three model families:

- **Claude sub-agents**: Opus, Sonnet and Haiku tiers, through the Agent tool.
- **OpenAI Codex CLI**: the GPT-6.x family. This lane also handles **image generation**, which Claude can't do.
- **Google Gemini**: Gemini 4 Argon and 3.8 Flash, through the Antigravity CLI `agy`.

The main session plans, writes briefs, makes the hard calls and writes the final synthesis. Each piece of work goes to the cheapest lane that can carry it, or to the family that is best at it.

## Contents

```
skills/
  orchestration/   routing policy: which lane gets what, brief style per lane, patterns, rules
  codex/           bridge to `codex exec` (modes: task, image, opinion, bulk, ask, review) + codex.ps1
  codex-image/     detailed art-direction brief template for image generation via gpt-6.1-sol
  gemini/          bridge to Gemini via `agy` (modes: research, digest, opinion, ask, task, bulk) + gemini.ps1
agents/
  deep-worker.md     Opus   – multi-file implementation, real debugging, judgment-heavy work
  scoped-worker.md   Sonnet – scoped edits, pattern clones, templated changes
  researcher.md      Sonnet – read-only wide reading, returns conclusions with pointers
  bulk-processor.md  Haiku  – mechanical batch work under exact rules
  verifier.md        Sonnet – read-only check of another agent's "done" claim
install.ps1        installs skills and agents into ~/.claude (copy, or -Link for symlinks)
```

## Routing at a glance

| Work | Lane |
|---|---|
| Plan, hard judgment, integration, synthesis | main Claude session |
| Medium-high implementation / debugging | `deep-worker` (Opus) |
| Scoped edits, lookups | `scoped-worker` (Sonnet) |
| Wide reading → conclusion | `researcher` (Sonnet) or Gemini `digest` |
| Verify a delegate's claim | `verifier` (Sonnet) |
| Bulk mechanical data work | `bulk-processor` (Haiku) or `gpt-6-luna` |
| **Images: generate or edit** | `gpt-6.1-sol` via `codex-image` |
| GPT-side execution | `gpt-6.1-sol` (`codex -Mode task`) |
| Second opinion | `gpt-6-astra` (`codex -Mode opinion`) |
| Current web facts with sources | Gemini `research` |
| Third opinion / multi-model consensus | Gemini `opinion` + astra in parallel |

## Requirements

- Windows with **PowerShell 7** (`pwsh`). The bridge scripts use PS7 syntax.
- [Claude Code](https://claude.com/claude-code).
- **Codex CLI** version 0.167 or later, signed in. Older versions reject the GPT-6.x models.
  ```
  npm i -g @openai/codex
  codex login
  ```
- **Google Antigravity**, signed in once. It provides `agy`. The standalone `gemini` CLI no longer accepts personal Google accounts.

## Install

```powershell
pwsh -File install.ps1 -Check   # see which external CLIs are present
pwsh -File install.ps1          # copy into ~/.claude/skills and ~/.claude/agents
pwsh -File install.ps1 -Link    # or symlink, so `git pull` updates them (may need Developer Mode on Windows)
```

Then start a new Claude Code session. The agents are loaded when a session starts.

## Using the bridges directly

```powershell
$codex  = "$HOME\.claude\skills\codex\scripts\codex.ps1"
$gemini = "$HOME\.claude\skills\gemini\scripts\gemini.ps1"

pwsh -File $codex  -Mode image   -PromptFile brief.md -Out assets\hero.png
pwsh -File $codex  -Mode image   -Session <CODEX_THREAD_ID> -Prompt "Keep everything; change only: ..."
pwsh -File $codex  -Mode task    -Cd C:\proj -Write -PromptFile steps.md
pwsh -File $codex  -Mode opinion -PromptFile question.md
pwsh -File $gemini -Mode research -Prompt "Latest stable X as of today?"
pwsh -File $gemini -Mode digest   -Cd C:\proj -PromptFile question.md
```

Each script ends with machine-readable lines:
- Codex: `CODEX_IMAGE=`, `CODEX_THREAD_ID=` and `CODEX_STATUS=ok|error`
- Gemini: `GEMINI_SESSION_ID=` and `GEMINI_STATUS=ok|error`

## Notes and caveats

- **Briefs sent to external lanes go to OpenAI or Google.** Keep secrets and private data out of them.
- **Images.** Codex saves the images it generates under `~/.codex/generated_images/<thread_id>/`. `codex.ps1` copies them from there to `-Out`. It checks that each file really is a PNG, JPEG or WebP, so an SVG drawn as a fallback is rejected.
- **Sandboxes.** Lanes run read-only by default. File writes need `-Write` and are limited to `-Cd`. The scripts never use the "bypass all approvals" flags.
- **Gemini research** can lag the live web. The lane is told to flag what it could not confirm, so cross-check anything decision-critical.
- **Credits.** The routing policy is adapted from a user-supplied "fable-orchestration" delegation policy and extended with Gemini lanes and named Claude agents.
