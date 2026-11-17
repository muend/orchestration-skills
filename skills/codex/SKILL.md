---
name: codex
description: "Bridge to the local OpenAI Codex CLI (GPT-6.2 Astra / Sol, GPT-6 Luna) as a sub-agent. Use when the user asks to send work to Codex/GPT/OpenAI, wants a second opinion from a different model family, needs something Claude cannot do natively (image generation or image editing — see the codex-image skill for the brief format), wants bulk mechanical data cleanup on a cheap lane, wants a Codex code review of a repo/diff, needs a hard high-stakes judgment from GPT-6.2 Astra (scout → judge with an evidence pack), or wants several Codex lanes run in parallel (a 'codex fleet'). Knows the subscription limit economy: guards Astra and high effort, logs every lane's cost. Also load whenever the orchestration skill routes a lane to gpt-6.2-sol, gpt-6.2-astra or gpt-6-luna."
---

# Codex sub-agent bridge

Codex CLI (`codex exec`) runs non-interactively on this machine, signed in with the user's ChatGPT account.
Always call it through the wrapper script — it handles stdin prompts (UTF-8, no quoting problems), the
JSON event stream, sandbox choice, per-mode model defaults, evidence packs, the effort and limit guards,
the cost ledger, session resume, and copying generated images out of Codex's private folder.

```
pwsh -NoProfile -File "$HOME\.claude\skills\codex\scripts\codex.ps1" -Mode <mode> -PromptFile <brief.md> [-Lane <name>] [options]
```

Use the PowerShell tool (or Bash with `pwsh -NoProfile -File ...`). Runs take 20 s – several minutes:
set `timeout` to 600000, or `run_in_background: true` for long tasks and fleets. Always pass `-Lane` with a short
name so the ledger shows which piece of work spent what.

## Models (GPT-6.2, released 2026-11-17)

| Model | What it is | Use it for |
|---|---|---|
| **gpt-6.2-astra** | OpenAI's frontier model; strongest and smartest; strongest cybersecurity model yet; default Codex context 272k | The hardest, highest-stakes judgments only: security verdicts, architecture-critical calls, strategy, adjudication, a fix that already failed on Sol. **Burns the subscription limit fast.** |
| **gpt-6.2-sol** | The efficient everyday model; within ~0.5 pt of Astra on a frontier coding eval at ~1/5 the cost; default context 500k | Default GPT lane: execution, code, reviews, images, scouting/large reads, multi-source synthesis |
| gpt-6-luna | Cheapest | Bulk mechanical work under exact rules |

There is no gpt-6.2-luna or gpt-6.2-terra (checked 2026-11-17). Older ids still work (`gpt-6.1-sol`, `gpt-6.1-terra`,
`gpt-6-astra`). If a model is rejected, check the live roster with `codex debug models`; the account decides.
Both 6.2 models accept up to 1M context via `-c model_context_window=...`, only when a lane truly needs it.

**Known weakness:** Astra's system card says it omits known coding obstacles more often than GPT-6 Astra. The script
therefore appends a mandatory `## Obstacles / not verified` + `## Assumptions` ending to task/opinion/judge prompts, and
Claude verifies every claim that matters.

## Modes and lanes

| Mode | Default model / effort | Sandbox | Use for |
|---|---|---|---|
| `scout` | gpt-6.2-sol / medium | read-only | Wide reading → **evidence pack** (path:line excerpts per question, no verdicts) |
| `judge` | gpt-6.2-astra / high | read-only | Hard verdict **from an evidence pack** (`-Pack` required); at most `-MaxExtraFiles` (6) extra files |
| `task` | gpt-6.2-sol / medium | read-only; `-Write` → workspace-write in `-Cd` | Execution: code changes, scripts, file generation |
| `image` | gpt-6.2-sol / high | read-only (image comes out via the script) | Image generation / editing → **load `codex-image` first** |
| `opinion` | gpt-6.2-astra / high | read-only | Second opinion / peer review of a plan; pass `-Pack` when the question needs repo evidence |
| `bulk` | gpt-6-luna / low | read-only; `-Write` to let it write outputs | Large mechanical cleanup: normalize, dedupe, classify, extract |
| `ask` | gpt-6.2-sol / medium | read-only | Quick factual/technical question to the GPT family |
| `review` | gpt-6.2-sol / high | read-only | `codex exec review` on a git repo (`-Uncommitted`, `-Base main`, `-Commit <sha>`) |

Override with `-Model` and `-Effort low|medium|high|xhigh|max|ultra`.

## Effort rule (user, 2026-11-17)

**Stay at `medium` or `high`.** `medium` for routine and well-scoped work (OpenAI's own starting point), `high` for hard
work (tracing one cause across several systems, security, strategy, images). `xhigh` only when truly required (several
interacting causes) or after a `high` run failed verification for lack of reasoning — the script refuses it without
`-EffortReason "<why>"`. `max`/`ultra` (Codex's parallel-subagent mode) need the user's explicit OK — the script refuses them
without `-UserApproved`. Never raise effort to fix missing context, conflicting instructions or formatting: fix the brief.
API effort values: none, minimal, low, medium, high, xhigh, max (verified by sending an invalid value).

## Limit economy (subscription sign-in; measured 2026-11-17 on Plus)

Codex usage is metered against a **5-hour window** and a **weekly window**, by tokens. Measured: three Astra lanes at
`xhigh` plus one Sol lane, in parallel, took the 5-hour window from 47 % to 99 % within about 20 minutes. About 90 % of each lane's tokens were
*cached input*: every tool call re-sends the whole conversation, so **turns × context size** is what burns the limit, far
more than the answer. Astra exploring a repository is the most expensive thing you can buy; on the previous generation's
published estimates Astra got roughly a third as many messages per window as Sol.

1. **Default to Sol.** Astra only where its extra judgment changes the outcome.
2. **Scout → judge.** Astra never explores. A scout builds the evidence pack first — preferably a lane outside the Codex
   limit (Claude `researcher`, Gemini `digest`), else `-Mode scout` (Sol, medium). Then `-Mode judge -Pack pack.md`.
3. **One Astra lane at a time.** Fan out Sol, Claude or Gemini lanes instead.
4. **Built-in limit guard** (reads the newest `rate_limits` from `~/.codex/sessions`): Astra is refused at ≥ 60 % of the
   5-hour window or ≥ 75 % weekly; every Codex lane is refused at ≥ 85 % 5-hour or ≥ 90 % weekly. Refusal prints
   `CODEX_STATUS=blocked` (exit 3): reroute (Sol → Claude/Gemini) or wait for the reset. `-Force`/`-UserApproved` only when
   the user asks.
5. **Bound the work:** a narrow question, "top N, not everything", explicit stop conditions.
6. **Follow-ups continue the thread** with `-Session <id>` (cached prefix, unchanged instructions) instead of a cold lane.
7. **A lane stopped by the limit is not lost** (`CODEX_STATUS=limit`, exit 4): resume it with `-Session <id>` after the reset.
8. **Measure:** every run is logged; review with `python ~/.claude/skills/orchestration/scripts/ledger.py` and adjust routing.

## Watching and measuring

- **Live:** `python ~/.claude/skills/codex/scripts/codex-watch.py --since HH-MM --n 4` — each lane's task title, model/effort,
  state, tokens (cached/output) and last commands, plus the 5-hour/weekly limit. `--limit` prints only the limit line.
  Read-only; it never stops a lane.
- **Ledger:** `~/.claude/orchestration/ledger.jsonl` (one line per run: lane, mode, model, effort, status, seconds, tokens,
  5-hour and weekly limit before/after). Gemini runs write to the same ledger.
- **Dry run:** `-DryRun` prints the final prompt, the codex arguments and the guard decision without calling Codex (free).

## Other options

`-Cd <dir>` working root · `-Pack a.md,b.md` evidence pack · `-Images a.png,b.png` attach images · `-Out <file>` save final
message (or image path in image mode) · `-Schema schema.json` force a JSON-shaped final answer ·
`-Session <thread-id>` continue a previous conversation · `-Count N` image variants ·
`-ImageProfile <role>` image role preset from `image-profiles.json` · `-Transparent` transparent background.

**Subscription only.** Codex runs on the user's ChatGPT subscription sign-in (Plus or Pro). Never set or ask for
`OPENAI_API_KEY` and never use Codex's image "CLI fallback" (it bills the API). On this path the built-in image tool has
no model/quality/size parameter, so a specific image model (e.g. GPT Image 2.6 Sunburst/Flare) cannot be
selected — say so if asked, and use role profiles + a precise brief instead.

## Output contract

The script prints Codex's final message, then machine-readable lines:

```
CODEX_LIMIT_BEFORE=5h:..% week:..% plan:..
CODEX_IMAGE=C:\...\out.png      (image mode, one per image)
CODEX_ERROR=...                 (if any)
CODEX_BLOCKED=<reason>          (guard refused the run)
CODEX_TOKENS=in:.. cached:.. out:..
CODEX_LIMIT_AFTER=5h:..% week:..%
CODEX_THREAD_ID=01a1...         (pass to -Session for follow-ups/iterations/resume)
CODEX_STATUS=ok|error|blocked|limit|dryrun   (exit 0 | 1 | 3 | 4 | 0)
```

## How to brief each lane (this is the quality ceiling)

Long briefs always go in a file (scratchpad), passed with `-PromptFile`. Never squeeze a detailed brief
into a one-line `-Prompt`.

**OpenAI's rules for GPT-6.2 in Codex (all lanes):** write it like a request to a colleague who knows the project; state
what counts as finished and where it must be exhaustive; say what you will check when you review; give conventions and
caller-relied behavior it cannot infer; leave routine how-to decisions to the model; ask it to verify before finishing; do
not add "be concise" (6.2 is concise by default); keep the instruction prefix unchanged when continuing a `-Session`.

- **gpt-6.2-sol (task/image) — complete and decided.** Sol carries out the brief faithfully. Decide open design questions
  yourself first; hand it decisions, not dilemmas; leave the routine how-to to it. Use this skeleton:

  ```markdown
  # Goal
  <one paragraph: what and why>
  # Context
  <facts it cannot discover: stack, conventions, related files, prior decisions, behavior callers rely on>
  # Requirements
  1. <what must be true, with exact paths> — Check: <how to verify it>
  2. ...
  # Edge cases
  - <case> → <what to do>
  # Out of scope / do not touch
  - ...
  # Done when
  <acceptance checks; where it must be exhaustive; exact files/format of the final reply>
  ```

- **scout (Sol) — question-shaped.** The numbered questions the judge will need answered, where to look first, what to
  skip (secrets, caches, vendored code), and the pack size cap. No conclusions wanted.

- **gpt-6.2-astra (judge/opinion) — a senior peer question.** The decision, the evidence pack, the options you see and
  where you are unsure; what the verdict must cover. Do NOT hand it your conclusion to rubber-stamp. Treat the answer as
  peer review: weigh it, disagree on evidence, tell the user where the models differ.

- **gpt-6-luna (bulk) — one exact rule set.** State the rules mechanically with 2–3 input → output
  examples. Split data into batches small enough that a bad batch is cheap to redo; one output file per
  batch; spot-check samples before merging. Never ask luna to decide what the rules should be.

## Fleet (parallel lanes)

For independent pieces, write one brief file per lane with the model stamped in it, then launch each as a
separate background command (`run_in_background: true`), each with its own `-Out` file, `-Lane` name and, for writers,
its own `-Cd` folder or worktree. Two writing lanes must never share files. **Fleets are Sol/Luna lanes; at most one
Astra lane runs at a time.** Check `codex-watch.py --limit` before launching. Collect results when the notifications
arrive; verify each before merging.

## Rules

1. **A Codex report is a claim.** Check the diff, run the tests, open the output file, or look at the
   image (Read the PNG) before telling the user it is done. Read its "Obstacles / not verified" section first.
2. Default sandbox is read-only. Grant `-Write` only for `task`/`bulk` and only inside the intended
   folder. Never use `--dangerously-bypass-approvals-and-sandbox`.
3. Do not send secrets, credentials or private data the user has not cleared into a brief or a pack — they go to OpenAI.
   Tell read-only lanes which files never to open (`.env*`, `.dev.vars`, keys, caches).
4. Small things (one file, a handful of tool calls) do yourself; a delegation costs more than it saves.
5. On `CODEX_STATUS=error`: read `CODEX_ERROR`. `model_not_found` → pick another model from
   `codex debug models`; auth errors → ask the user to run `codex login`; never loop retries blindly.
   On `blocked` → follow the reason (reroute or wait); on `limit` → resume with `-Session` after the reset.
6. Iterating on the same work → reuse `-Session <thread-id>` so Codex keeps its context.
