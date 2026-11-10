---
name: gemini
description: "Bridge to Google Gemini (Gemini 4 Argon / Gemini 3.8 Flash) through the local Antigravity CLI (`agy`, Google AI Pro sign-in, no API fees) as a sub-agent. Use for DEEP RESEARCH (multi-source investigations and cited reports run on Gemini 4 Argon), current facts from the web with source URLs, very large-context reading (a whole repo, many long documents) that should not enter Claude's context, a third independent opinion from a different model family, or when the user asks to send work to Gemini/Google. Also load whenever the orchestration skill routes a lane to Gemini."
---

# Gemini sub-agent bridge (Antigravity `agy`)

The old `gemini` CLI can no longer sign in with personal Google accounts ("This client is no longer
supported for Gemini Code Assist for individuals… migrate to Antigravity"). The Antigravity CLI `agy`
is installed and signed in with the user's Google AI Pro account, so this bridge uses it — **subscription
only; never use or ask for a `GEMINI_API_KEY`.** Always call through the wrapper:

```
pwsh -NoProfile -File "$HOME\.claude\skills\gemini\scripts\gemini.ps1" -Mode <mode> -PromptFile <brief.md> [options]
```

Runs take 10 s – several minutes (deep research up to ~60 min): `timeout: 600000` or
`run_in_background: true`.

## Modes

| Mode | Default model | Writes? | Use for |
|---|---|---|---|
| `deepresearch` | **gemini-4-argon-high** | no | Multi-step investigation → cited Markdown report (plan → search → cross-check → synthesize). Use `-Out report.md`. 60-min default timeout |
| `research` | gemini-4-argon-high | no | Quick current facts with a URL per claim |
| `digest` | gemini-4-argon-high | no | Read a big area (`-Cd`, `-Include dirA,dirB`) and return only the conclusion with file:line |
| `opinion` | gemini-4-argon-high | no | Independent peer review / third opinion |
| `ask` | gemini-4-argon-medium | no | Quick question |
| `task` | gemini-4-argon-high | only with `-Write` (accept-edits in `-Cd`) | Execution by Gemini (when the user asks for it) |
| `bulk` | gemini-3.8-flash-medium | only with `-Write` | Mechanical batch work under exact rules |

`gemini-4-argon-high` is Argon's top level (effort is part of the model name; `agy --effort` conflicts
with it). Override with `-Model` (`agy models`). `agy` also lists Claude and GPT-OSS models — don't route
Claude work through it; use the Agent tool. Other options: `-Out <file>` · `-Session <GEMINI_SESSION_ID>` ·
`-Include <dirs>` · `-TimeoutSec`.

Implementation notes (already handled by the script): `agy --mode plan` is a "plan and wait for approval"
mode, not read-only, so read-only modes run without `--mode` and are told not to write, not to stop for
approval and not to run shell commands (headless runs auto-deny them). Prompts go as an argument (agy
ignores stdin); briefs over ~20K chars are passed via a temp file.

## Output contract

Final answer text, then `GEMINI_WARNING=` (blocked actions, if any), `GEMINI_ERROR=` (if any),
`GEMINI_TOKENS=`, `GEMINI_SESSION_ID=`, `GEMINI_STATUS=ok|error` (exit 1 on error or empty answer).

## Briefing

- **deepresearch:** the research question and the decision it feeds; scope in/out; sub-topics you
  already know matter; recency ("as of <date>"); preferred source types (papers, official docs, filings);
  target length and language of the report. Always pass `-Out`. Afterwards spot-check the citations that
  carry the conclusion (open 2–3 URLs, or send a `verifier`/`researcher`), and surface the report's
  "Contradictions & open questions" to the user.
- **research:** the exact question, recency requirement, source types, answer length. Gemini's search can
  lag the live web; it is told to flag what it could not confirm — pass those gaps on.
- **digest:** exact paths, the question, answer format, "file:line for every claim". Prefer this over
  reading dozens of files into Claude's own context.
- **opinion:** same neutral peer brief you'd give gpt-6-astra (problem, evidence, options, uncertainty) —
  never your conclusion to rubber-stamp. Run in parallel with astra for multi-model consensus.
- **task/bulk:** same detailed step/acceptance or rule/example format as the codex skill.

## Rules

1. Gemini's answer is a claim: verify code changes and spot-check cited sources before relying on them.
2. Briefs go to Google: no secrets, credentials or private data the user hasn't cleared.
3. Never pass `--dangerously-skip-permissions`; write access only via `-Write` inside the intended folder.
4. On `GEMINI_STATUS=error` with an auth message, ask the user to open Antigravity / run `agy` once and
   sign in; don't loop retries.
