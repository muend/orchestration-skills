---
name: codex
description: "Bridge to the local OpenAI Codex CLI (GPT-6.x family) as a sub-agent. Use when the user asks to send work to Codex/GPT/OpenAI, wants a second opinion from a different model family, needs something Claude cannot do natively (image generation or image editing — see the codex-image skill for the brief format), wants bulk mechanical data cleanup on a cheap lane, wants a Codex code review of a repo/diff, or wants several Codex lanes run in parallel (a 'codex fleet'). Also load whenever the orchestration skill routes a lane to gpt-6.2-sol, gpt-6.2-astra or gpt-6-luna."
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
| `task` | gpt-6.2-sol / medium | read-only; `-Write` → workspace-write in `-Cd` | Execution: code changes, scripts, file generation, done by GPT |
| `image` | gpt-6.2-sol / high | read-only (image comes out via the script) | Image generation / editing → **load `codex-image` first** |
| `opinion` | gpt-6.2-astra / high | read-only | Second opinion, out-of-the-box angle, peer review of a plan |
| `bulk` | gpt-6-luna / low | read-only; `-Write` to let it write outputs | Large mechanical cleanup: normalize, dedupe, classify, extract |
| `ask` | gpt-6.2-sol / medium | read-only | Quick factual/technical question to the GPT family |
| `review` | gpt-6.2-sol / high | read-only | `codex exec review` on a git repo (`-Uncommitted`, `-Base main`, `-Commit <sha>`) |

**Model choice (user, 2026-11-17):** gpt-6.2-astra is the strongest, smartest GPT model; gpt-6.2-sol is strong but more efficient. For the hardest work (security audit, architecture, strategy, hard engineering) run `-Mode task -Model gpt-6.2-astra`; keep sol for well-specified execution, images, reviews and medium tasks.

Override with `-Model` (`gpt-6.2-sol`, `gpt-6.2-astra`, `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-astra`, `gpt-6-luna`; 6.2 has only sol and astra, verified 2026-11-17) and
`-Effort low|medium|high|xhigh|max|ultra`.

**Effort rule (user, 2026-11-17): stay at `medium` or `high`.** `medium` for routine and well-scoped work (OpenAI's own starting
point), `high` for hard work (tracing one cause across several systems, security, strategy). Go to `xhigh` only when it is
truly required (several interacting causes) or after a `high` run failed verification for lack of reasoning, and say why in
the lane spec. `max`/`ultra` are not used without the user's explicit OK. Never raise effort to fix missing context, conflicting
instructions or formatting: fix the brief instead.

## GPT-6.2 facts (OpenAI docs + launch coverage, 2026-11-17)

- **gpt-6.2-astra** — OpenAI's frontier model for the hardest end-to-end work: bugs spanning services, security
  (its strongest cybersecurity model yet), research, architecture, strategy, matching a screenshot/visual reference, making
  and testing changes inside an existing project. Default Codex context 272k tokens.
- **gpt-6.2-sol** — the efficient everyday model ("complex work at lower cost"): within ~0.5 pt of Astra on a frontier
  coding eval at about one fifth of the cost; default Codex context 500k tokens. First choice for routine code, writing,
  reviews, images, multi-source synthesis, and any large-context read.
- Both can be given up to 1M context via `-c model_context_window=...` (only when a lane truly needs it).
- **Known weakness:** Astra's system card says it omits known coding obstacles more often than GPT-6 Astra. Every brief
  therefore asks for an explicit "Engeller / doğrulanamayanlar" (obstacles / unverified) section, and Claude verifies claims.
- Effort values the API accepts: none, minimal, low, medium, high, xhigh, max (verified 2026-11-17 by sending an invalid value).
  The CLI also passes `ultra` (Codex's parallel-subagent mode). Ignore third-party guides that name other model IDs.

**Brief rules from OpenAI's Codex guide:** write it like a request to a colleague who knows the project; state what counts as
finished and where it must be exhaustive; say what you will check when you review; give conventions and caller-relied
behavior it cannot infer; leave routine how-to decisions to the model; ask it to verify its own work before finishing; do not
add "be concise" (6.2 is concise by default); keep the instruction prefix unchanged when continuing a `-Session`.

## Limit economy (ChatGPT Plus sign-in; measured 2026-11-17)

Codex usage is metered against a **5-hour window** and a **weekly window** (`rate_limits` in the session log). Measured: three
Astra lanes at `xhigh` running in parallel moved the 5-hour window from 47 % to 71 % in a few minutes. About 90 % of each lane's
tokens were *cached input*: every tool call re-sends the whole conversation, so **the number of turns × context size** is what
burns the limit, far more than the answer itself. Repo exploration by Astra is therefore the most expensive thing you can buy.

1. **Default to Sol.** Astra only where its extra judgment changes the outcome: final verdict on security, architecture,
   strategy, adjudicating disagreements, a fix that already failed on Sol.
2. **Scout → judge.** Wide reading never runs on Astra. A scout builds an evidence pack first (file:line excerpts, ≤ ~40k
   tokens): preferably a lane outside the Codex limit (Claude `researcher`, Gemini `digest`), else Sol at `medium`. Astra then
   gets the pack in the brief with "work from this pack; open at most N extra files, name them first".
3. **One Astra lane at a time** on Plus. Never fan out Astra fleets; fan out Sol or Claude lanes instead.
4. **Check the limit before launching Astra:** `python codex-watch.py --limit`. 5-hour window above ~60 % → wait for the
   reset or use Sol; above ~85 % → no new Codex lanes at all.
5. **Effort `medium`/`high` only** (see the effort rule). `xhigh` multiplies reasoning tokens on every turn.
6. **Bound the work:** a narrow question, "top 5, not everything", an output length cap, explicit stop conditions.
7. **Follow-ups continue the thread** with `-Session <id>` (cached prefix) instead of a cold new lane that re-reads the repo.
8. **A lane stopped by the limit is not lost:** resume it with `-Session <id>` after the reset.
9. **Record each heavy lane's cost** (limit % before/after, from `--limit`) next to its output so the routing keeps improving.

**Watching lanes live:** `python ~/.claude/skills/codex/scripts/codex-watch.py --since HH-MM --n 4` prints each running lane's
task title, model/effort, state, tokens and last commands from `~/.codex/sessions`, plus the current 5-hour/weekly limit
(`--limit` prints only the limit line). It only reads; it never stops a lane.
Check the live roster with `codex debug models` if a model is rejected (the account decides what is available).

Other options: `-Cd <dir>` working root · `-Images a.png,b.png` attach images · `-Out <file>` save final
message (or image path in image mode) · `-Schema schema.json` force a JSON-shaped final answer ·
`-Session <thread-id>` continue a previous conversation · `-Count N` image variants ·
`-ImageProfile <role>` image role preset from `image-profiles.json` · `-Transparent` transparent background.

**Subscription only.** Codex runs on the user's ChatGPT subscription sign-in (Plus or Pro). Never set or ask for `OPENAI_API_KEY`
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

- **gpt-6.2-sol (task/image) — detailed, complete, step by step.** Sol does exactly what the brief says,
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

- **gpt-6.2-astra (opinion) — a peer question.** Give the problem, the evidence, the options you see and
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
