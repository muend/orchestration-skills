<#
.SYNOPSIS
  Claude -> Gemini köprüsü (Google Antigravity CLI: `agy`). Gemini'yi non-interactive bir subagent olarak çalıştırır.
  Not: Eski `gemini` CLI kişisel Google hesaplarıyla artık giriş yapamıyor ("migrate to Antigravity"); bu yüzden agy kullanılır.

.EXAMPLE
  pwsh -File gemini.ps1 -Mode ask      -Prompt "..."
  pwsh -File gemini.ps1 -Mode research -PromptFile brief.md          # güncel web bilgisi, kaynaklı
  pwsh -File gemini.ps1 -Mode digest   -Cd C:\proj -PromptFile q.md  # büyük bağlam: tüm repo / uzun dokümanlar
  pwsh -File gemini.ps1 -Mode opinion  -PromptFile question.md
  pwsh -File gemini.ps1 -Mode task     -Cd C:\proj -Write -PromptFile brief.md

  Çıktı sonunda:  GEMINI_SESSION_ID=<conversation id> · GEMINI_TOKENS=... · GEMINI_STATUS=ok|error
#>
[CmdletBinding()]
param(
  [ValidateSet('ask', 'research', 'digest', 'opinion', 'task', 'bulk')]
  [string]$Mode = 'ask',
  [string]$Prompt,
  [string]$PromptFile,
  [string]$Model,                 # boşsa mod varsayılanı; liste: agy models
  [string]$Cd,
  [switch]$Write,                 # task/bulk: dosya düzenlemeye izin ver (accept-edits). Asla skip-permissions değil.
  [string[]]$Include,             # ek klasörler (--add-dir)
  [string]$Out,                   # son cevabı dosyaya da yaz
  [string]$Session,               # önceki konuşmaya devam (--conversation <id>)
  [int]$TimeoutSec = 1800
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$agy = Get-Command agy -ErrorAction SilentlyContinue
if (-not $agy) { Write-Output "GEMINI_STATUS=error"; Write-Error "agy (Antigravity CLI) bulunamadı"; exit 2 }
if ($PromptFile) { $Prompt = Get-Content -Raw -Encoding utf8 $PromptFile }
if (-not $Prompt) { Write-Error "-Prompt veya -PromptFile gerekli"; exit 2 }
if (-not $Cd) { $Cd = (Get-Location).Path }
$Cd = (Get-Item -LiteralPath (Resolve-Path $Cd).Path).FullName

# --- mod başına varsayılan model (effort model adının içinde) ----------------
$laneModel = @{
  ask = 'gemini-4-argon-medium'; research = 'gemini-4-argon-high'; digest = 'gemini-4-argon-high'
  opinion = 'gemini-4-argon-high'; task = 'gemini-4-argon-high'; bulk = 'gemini-3.8-flash-medium'
}
if (-not $Model) { $Model = $laneModel[$Mode] }

$wrap = switch ($Mode) {
  'ask' { "You are consulted as a subagent by another AI assistant (Claude). Answer directly and concisely. Do not modify files." }
  'research' { @"
You are a research subagent for another AI assistant (Claude). Use your web search / fetch tools to get CURRENT information.
Rules: cite a source URL for every factual claim; prefer primary sources; give dates for time-sensitive facts;
separate verified facts from inference; say clearly when something could not be confirmed. Do not modify files.
Reply: 1) direct answer, 2) evidence list with URLs, 3) gaps/uncertainties.
"@ }
  'digest' { @"
You are a large-context reading subagent for another AI assistant (Claude). Read the files/directories the brief points to
(use your file read / list / search tools on the workspace; read as much as needed - your context is large).
Return only the conclusion the brief asks for, with file:line pointers for each claim. Do not modify files.
"@ }
  'opinion' { @"
You are consulted as an independent peer reviewer by another AI assistant (Claude). Do not just confirm.
Structure: 1) your own read, 2) risks/blind spots, 3) alternatives, 4) recommendation. Disagree on evidence. Do not modify files.
"@ }
  'task' { @"
You are an execution subagent for another AI assistant (Claude). Complete the brief in the working directory.
Follow numbered steps in order with each acceptance check; do not add unrequested changes; do not touch out-of-scope items.
If a step cannot be done as written, stop and report. Never commit, push or delete data.
Final reply: per-step status, files changed, verification commands + results, unfinished items.
"@ }
  'bulk' { @"
You are a bulk data-processing subagent. Apply the rule set EXACTLY and mechanically; mark non-matching items UNMATCHED.
Write outputs only where the brief says. Finish with counts processed / changed / unmatched.
"@ }
}
$full = "$wrap`n`n===== BRIEF =====`n$Prompt`n===== END BRIEF ====="

# agy stdin okumuyor -> prompt argüman olarak gider. Windows komut satırı ~32K sınırı için
# uzun brief'ler geçici dosyaya yazılır ve agy'ye o dosyayı okuması söylenir.
$tmp = $null
if ($full.Length -gt 20000) {
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-brief-{0}.md" -f [guid]::NewGuid().ToString('N'))
  Set-Content -Encoding utf8 -Path $tmp -Value $full
  $tmpLong = (Get-Item -LiteralPath $tmp).FullName
  $full = "Read the file $tmpLong completely and follow it exactly as your instructions. It is the full brief from Claude."
  $Include += (Split-Path $tmpLong)
}

$agyMode = if ($Mode -in 'task', 'bulk' -and $Write) { 'accept-edits' } else { 'plan' }
$cmdArgs = @("-p=$full", '--output-format', 'json', '--mode', $agyMode, '--model', $Model, '--print-timeout', "${TimeoutSec}s")
if ($Session) { $cmdArgs += @('--conversation', $Session) }
foreach ($d in $Include) { $cmdArgs += @('--add-dir', (Get-Item -LiteralPath (Resolve-Path $d).Path).FullName) }

Push-Location $Cd
try {
  $raw = (& $agy.Source @cmdArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $exit = $LASTEXITCODE
} finally { Pop-Location; if ($tmp) { Remove-Item $tmp -ErrorAction SilentlyContinue } }

$status = 'error'; $resp = ''; $sid = $null; $err = $null; $tok = $null
$jsonStart = $raw.IndexOf('{"')
if ($jsonStart -ge 0) {
  try {
    $j = $raw.Substring($jsonStart) | ConvertFrom-Json -ErrorAction Stop
    $resp = $j.response
    $sid  = $j.conversation_id
    if ($j.usage) { $tok = "in:$($j.usage.input_tokens) out:$($j.usage.output_tokens) think:$($j.usage.thinking_tokens)" }
    if ($j.status -eq 'SUCCESS' -and $exit -eq 0) { $status = 'ok' } else { $err = "status=$($j.status) $($j.error)" }
  } catch { $err = "JSON çözülemedi: $($raw.Substring(0, [Math]::Min(500, $raw.Length)))" }
} else { $err = if ($raw) { $raw.Substring(0, [Math]::Min(500, $raw.Length)) } else { "boş çıktı (exit $exit)" } }

if ($resp) { Write-Output $resp }
if ($Out -and $resp) { Set-Content -Encoding utf8 -Path $Out -Value $resp }
if ($err) { Write-Output "GEMINI_ERROR=$err" }
if ($tok) { Write-Output "GEMINI_TOKENS=$tok" }
if ($sid) { Write-Output "GEMINI_SESSION_ID=$sid" }
Write-Output "GEMINI_STATUS=$status"
if ($status -ne 'ok') { exit 1 }
