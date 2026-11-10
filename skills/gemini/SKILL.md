---
name: gemini
description: "Bridge to Google Gemini (Gemini 4 Argon / Gemini 3.8 Flash) through the local Antigravity CLI (`agy`) as a sub-agent. Use for current facts from the web with source URLs, very large-context reading (a whole repo, many long documents) that should not enter Claude's context, a third independent opinion from a different model family, or when the user asks to send work to Gemini/Google. Also load whenever the orchestration skill routes a lane to Gemini."
---

# Gemini sub-agent bridge (Antigravity `agy`)

The old `gemini` CLI can no longer sign in with personal Google accounts ("This client is no longer
supported for Gemini Code Assist for individuals… migrate to Antigravity"). The Antigravity CLI `agy`
is installed and signed in, so this bridge uses it. Always call through the wrapper:

```
pwsh -NoProfile -File "$HOME\.claude\skills\gemini\scripts\gemini.ps1" -Mode <mode> -PromptFile <brief.md> [options]
```

Runs take 10 s – several minutes: `timeout: 600000` or `run_in_background: true`.

## Modes

| Mode | Default model | Permissions | Use for |
|---|---|---|---|
| `research` | gemini-4-argon-high | plan (read-only) | Current facts with a URL per claim; recency-sensitive questions |
| `digest` | gemini-4-argon-high | plan | Read a big area (`-Cd`, `-Include dirA,dirB`) and return only the conclusion with file:line |
| `opinion` | gemini-4-argon-high | plan | Independent peer review / third opinion |
| `ask` | gemini-4-argon-medium | plan | Quick question |
| `task` | gemini-4-argon-high | plan; `-Write` → accept-edits in `-Cd` | Execution by Gemini (when the user asks for it) |
| `bulk` | gemini-3.8-flash-medium | plan; `-Write` → accept-edits | Mechanical batch work under exact rules |

Override with `-Model` (list with `agy models`; effort is part of the name: `-low/-medium/-high`).
`agy` also lists Claude and GPT-OSS models — don't route Claude work through it; use the Agent tool.
Other options: `-Out <file>` · `-Session <GEMINI_SESSION_ID>` continue a conversation · `-Include <dirs>`.

## Output contract

Final answer text, then `GEMINI_ERROR=` (if any), `GEMINI_TOKENS=`, `GEMINI_SESSION_ID=`,
`GEMINI_STATUS=ok|error` (exit 1 on error).

## Briefing

- **research:** the exact question, the recency requirement ("as of <date>"), preferred source types,
  answer length. Gemini's search can lag the live web; it is told to flag what it could not confirm —
  pass those gaps on to the user instead of hiding them, and cross-check anything decision-critical.
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
