---
name: codex
description: "Bridge to the local OpenAI Codex CLI (GPT-6.x family) as a sub-agent. Use when the user asks to send work to Codex/GPT/OpenAI, wants a second opinion from a different model family, needs something Claude cannot do natively (image generation or image editing — see the codex-image skill for the brief format), wants bulk mechanical data cleanup on a cheap lane, wants a Codex code review of a repo/diff, or wants several Codex lanes run in parallel (a 'codex fleet'). Also load whenever the orchestration skill routes a lane to gpt-6.1-sol, gpt-6-astra or gpt-6-luna."
---

# Codex sub-agent bridge

Codex CLI (`codex exec`) runs non-interactively on this machine, signed in with the user's ChatGPT account.
Always call it through the wrapper script — it handles stdin prompts (UTF-8, no quoting problems), the
JSON event stream, sandbox choice, per-mode model defaults, session resume, and copying generated images
out of Codex's private folder.

```
pwsh -NoProfile -File "$HOME\.claude\skills\codex\scripts\codex.ps1" -Mode <mode> -PromptFile <brief.md> [options]
```

Use the PowerShell tool (or Bash with `pwsh -NoProfile -File ...`). Runs take 20 s – several minutes:
set `timeout` to 600000, or `run_in_background: true` for long tasks and fleets.

## Modes and lanes

| Mode | Default model / effort | Sandbox | Use for |
|---|---|---|---|
| `task` | gpt-6.1-sol / high | read-only; `-Write` → workspace-write in `-Cd` | Execution: code changes, scripts, file generation, done by GPT |
| `image` | gpt-6.1-sol / high | read-only (image comes out via the script) | Image generation / editing → **load `codex-image` first** |
| `opinion` | gpt-6-astra / high | read-only | Second opinion, out-of-the-box angle, peer review of a plan |
| `bulk` | gpt-6-luna / low | read-only; `-Write` to let it write outputs | Large mechanical cleanup: normalize, dedupe, classify, extract |
| `ask` | gpt-6.1-sol / medium | read-only | Quick factual/technical question to the GPT family |
| `review` | gpt-6.1-sol / high | read-only | `codex exec review` on a git repo (`-Uncommitted`, `-Base main`, `-Commit <sha>`) |

Override with `-Model` (`gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-sol`, `gpt-6-astra`, `gpt-6-luna`) and
`-Effort low|medium|high|xhigh`. Use `xhigh` only for an explicitly heavy lane.
Check the live roster with `codex debug models` if a model is rejected (the account decides what is available).

Other options: `-Cd <dir>` working root · `-Images a.png,b.png` attach images · `-Out <file>` save final
message (or image path in image mode) · `-Schema schema.json` force a JSON-shaped final answer ·
`-Session <thread-id>` continue a previous conversation · `-Count N` image variants ·
`-ImageProfile <role>` image role preset from `image-profiles.json` · `-Transparent` transparent background.

**Subscription only.** Codex runs on the user's ChatGPT Pro sign-in. Never set or ask for `OPENAI_API_KEY`
and never use Codex's image "CLI fallback" (it bills the API). On this path the built-in image tool has
no model/quality/size parameter, so a specific image model (e.g. GPT Image 2.6 Sunburst/Flare) cannot be
selected — say so if asked, and use role profiles + a precise brief instead.

## Output contract

The script prints Codex's final message, then machine-readable lines:

```
CODEX_IMAGE=C:\...\out.png      (image mode, one per image)
CODEX_ERROR=...                 (if any)
CODEX_TOKENS=in:.. out:..
CODEX_THREAD_ID=01a1...         (pass to -Session for follow-ups/iterations)
CODEX_STATUS=ok|error           (exit code 1 on error)
```

## How to brief each lane (this is the quality ceiling)

Long briefs always go in a file (scratchpad), passed with `-PromptFile`. Never squeeze a detailed brief
into a one-line `-Prompt`.

- **gpt-6.1-sol (task/image) — detailed, complete, step by step.** Sol does exactly what the brief says,
  nothing skipped, nothing added. Anything unsaid will not happen. Decide open design questions yourself
  first; hand it decisions, not dilemmas. Use this skeleton:

  ```markdown
  # Goal
  <one paragraph: what and why>
  # Context
  <facts it cannot discover: stack, conventions, related files, prior decisions>
  # Steps
  1. <action with exact path/command> — Acceptance: <how to check this step>
  2. ...
  # Edge cases
  - <case> → <what to do>
  # Out of scope / do not touch
  - ...
  # Deliverable
  <exact files/format expected; what the final reply must contain>
  ```

- **gpt-6-astra (opinion) — a peer question.** Give the problem, the evidence, the options you see and
  where you are unsure; ask what you may be missing. Do NOT hand it your conclusion to rubber-stamp.
  Treat the answer as peer review: weigh it, disagree on evidence, tell the user where the models differ.

- **gpt-6-luna (bulk) — one exact rule set.** State the rules mechanically with 2–3 input → output
  examples. Split data into batches small enough that a bad batch is cheap to redo; one output file per
  batch; spot-check samples before merging. Never ask luna to decide what the rules should be.

## Fleet (parallel lanes)

For independent pieces, write one brief file per lane with the model stamped in it, then launch each as a
separate background command (`run_in_background: true`), each with its own `-Out` file and, for writers,
its own `-Cd` folder or worktree. Two writing lanes must never share files. Collect results when the
notifications arrive; verify each before merging.

## Rules

1. **A Codex report is a claim.** Check the diff, run the tests, open the output file, or look at the
   image (Read the PNG) before telling the user it is done.
2. Default sandbox is read-only. Grant `-Write` only for `task`/`bulk` and only inside the intended
   folder. Never use `--dangerously-bypass-approvals-and-sandbox`.
3. Do not send secrets, credentials or private data the user has not cleared into a brief — the brief
   goes to OpenAI.
4. Small things (one file, a handful of tool calls) do yourself; a delegation costs more than it saves.
5. On `CODEX_STATUS=error`: read `CODEX_ERROR`. `model_not_found` → pick another model from
   `codex debug models`; auth errors → ask the user to run `codex login`; never loop retries blindly.
6. Iterating on the same work → reuse `-Session <thread-id>` so Codex keeps its context.
