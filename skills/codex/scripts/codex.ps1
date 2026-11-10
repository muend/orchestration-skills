<#
.SYNOPSIS
  Claude -> Codex CLI köprüsü. Codex'i (OpenAI GPT-6.x) non-interactive bir subagent olarak çalıştırır.

.EXAMPLE
  pwsh -File codex.ps1 -Mode ask   -Prompt "Bu regex neden yavaş? ^(a+)+$"
  pwsh -File codex.ps1 -Mode image -Prompt "Flat robot ikonu" -Out C:\proj\assets\robot.png
  pwsh -File codex.ps1 -Mode image -Prompt "Arka planı gün batımı yap" -Images C:\in.png -Out C:\out.png
  pwsh -File codex.ps1 -Mode task  -Cd C:\proj -Write -Prompt "tests/ altındaki kırık testi düzelt"
  pwsh -File codex.ps1 -Mode review -Cd C:\proj -Uncommitted
  pwsh -File codex.ps1 -Mode ask -Session <thread-id> -Prompt "Peki alternatifi ne?"

  Çıktının sonunda makinece okunur satırlar basılır:
    CODEX_THREAD_ID=<id>      (devam etmek için -Session ile kullan)
    CODEX_IMAGE=<path>        (image modunda, her görsel için bir satır)
    CODEX_STATUS=ok|error
#>
[CmdletBinding()]
param(
  [ValidateSet('ask', 'opinion', 'image', 'task', 'bulk', 'review')]
  [string]$Mode = 'ask',
  [string]$Prompt,
  [string]$PromptFile,
  [string]$Model,                       # örn. gpt-6.1-sol | gpt-6.1-terra | gpt-6-luna | gpt-6-astra ; boşsa config varsayılanı
  [ValidateSet('', 'low', 'medium', 'high', 'xhigh')]
  [string]$Effort = '',
  [string]$Cd,                          # çalışma klasörü (task/review); boşsa geçerli klasör
  [switch]$Write,                       # task modunda dosya yazmaya izin ver (workspace-write)
  [string[]]$Images,                    # girdi görselleri (-i)
  [string]$Out,                         # image: hedef dosya yolu | diğer: son mesajı bu dosyaya da yaz
  [string]$Schema,                      # JSON Schema dosyası -> yapılandırılmış final cevap
  [string]$Session,                     # önceki thread id ile devam et
  [int]$Count = 1,                      # image: kaç varyant
  [string]$ImageProfile = 'default',    # image: image-profiles.json içindeki rol profili
  [switch]$Transparent,                 # image: şeffaf arka plan
  [switch]$Uncommitted,                 # review: commitlenmemiş değişiklikler
  [string]$Base,                        # review: bu branch'e göre
  [string]$Commit,                      # review: tek commit
  [int]$TimeoutSec = 1800
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Write-Output "CODEX_STATUS=error"; Write-Error "codex CLI bulunamadı (npm i -g @openai/codex)"; exit 2
}

if ($PromptFile) { $Prompt = Get-Content -Raw -Encoding utf8 $PromptFile }
if (-not $Prompt -and $Mode -ne 'review') { Write-Error "-Prompt veya -PromptFile gerekli"; exit 2 }
if (-not $Cd) { $Cd = (Get-Location).Path }
$Cd = (Get-Item -LiteralPath (Resolve-Path $Cd).Path).FullName   # 8.3 kısa yolu (ör. USERNA~1) uzun yola çevir; sandbox kısa yolu reddediyor

# --- image: rol profili ---------------------------------------------------------
#   Sadece hesaba bağlı yol: Codex'in yerleşik image_gen aracı (ChatGPT girişi, API ücreti yok).
#   Bu araçta model/kalite/boyut parametresi yok; profil = role özel stil notları + şeffaflık.
if ($Mode -eq 'image') {
  $profPath = Join-Path (Split-Path $PSScriptRoot) 'image-profiles.json'
  $profiles = if (Test-Path $profPath) { Get-Content -Raw $profPath | ConvertFrom-Json -AsHashtable } else { @{} }
  if (-not $profiles.ContainsKey($ImageProfile)) {
    Write-Output "CODEX_ERROR=Bilinmeyen image profili '$ImageProfile'. Tanımlılar: $(($profiles.Keys | Where-Object { $_ -notlike '_*' }) -join ', ')"; Write-Output "CODEX_STATUS=error"; exit 1
  }
  $prof = $profiles[$ImageProfile]
  if (-not $Transparent -and $prof.transparent) { $Transparent = [switch]$true }
  if ($prof.style_notes -and -not $Session) { $Prompt = "$Prompt`n`n# Profile notes ($ImageProfile)`n$($prof.style_notes)" }
}

# --- mod başına varsayılan lane (orchestration politikası) -------------------
#   execution/image -> gpt-6.1-sol (brief'i harfiyen uygular)
#   opinion         -> gpt-6-astra (peer / farklı açı)
#   bulk            -> gpt-6-luna  (ucuz, mekanik toplu iş)
$laneModel  = @{ ask = 'gpt-6.1-sol'; task = 'gpt-6.1-sol'; image = 'gpt-6.1-sol'; review = 'gpt-6.1-sol'; opinion = 'gpt-6-astra'; bulk = 'gpt-6-luna' }
$laneEffort = @{ ask = 'medium'; task = 'high'; image = 'high'; review = 'high'; opinion = 'high'; bulk = 'low' }
if (-not $Model)  { $Model  = $laneModel[$Mode] }
if (-not $Effort) { $Effort = $laneEffort[$Mode] }

# --- prompt hazırlığı -------------------------------------------------------
switch ($Mode) {
  'opinion' {
    $Prompt = @"
You are consulted as an independent peer reviewer by another AI assistant (Claude).
Do not just confirm. Look for what may be missing, wrong, or a better angle; disagree on evidence.
Structure: 1) your own read of the problem, 2) risks/blind spots, 3) alternatives worth considering, 4) your recommendation.
Do not modify any files.

$Prompt
"@
  }
  'bulk' {
    $Prompt = @"
You are a bulk data-processing subagent. Apply the rule set below EXACTLY and mechanically.
Do not invent new rules; if an item does not fit any rule, mark it as UNMATCHED instead of guessing.
Write outputs only where the brief says. Finish with: counts processed / changed / unmatched.

$Prompt
"@
  }
  'ask' {
    $Prompt = @"
You are being consulted as a subagent by another AI assistant (Claude). Answer directly and concisely.
Do not modify any files. Reading files in the working directory is fine if it helps.

$Prompt
"@
  }
  'image' {
    $n = if ($Count -gt 1) { "Generate exactly $Count separate images (variants), one tool call each." } else { "Generate exactly one image." }
    if ($Transparent) { $n += " Call the tool with transparent_background=true and keep the subject cleanly isolated (no backdrop, no drop shadow unless the brief asks)." }
    $Prompt = @"
You are an image-production subagent for another AI assistant (Claude), who wrote a detailed art-direction brief.
Rules:
1. Use ONLY your built-in image generation tool. Do NOT write files, run shell commands, or draw SVG/HTML/code as a substitute.
2. Treat the brief as a specification. When you write the prompt for the image tool, carry over EVERY concrete detail:
   subject, composition, camera/framing, style, palette (keep hex codes), lighting, materials, exact text strings
   (verbatim, same spelling and case), aspect ratio/size, and every item under "Must NOT include".
   You may rephrase for the tool, but never drop, soften, or "improve" a stated constraint.
3. If input images are attached, they are references or the image to edit; follow the brief's instructions about which.
   For edits, change only what the brief asks to change and preserve everything else.
4. $n
5. Before finishing, check the result against the brief's acceptance checklist. If a must-have item is clearly violated
   (wrong text, wrong aspect, missing subject), regenerate once with a corrected prompt.
6. Final reply: for each image, one line "IMAGE <n>: <what it shows>; checklist: <passed items / failed items>".
   Then a line "TOOL PROMPT:" followed by the exact prompt you sent to the image tool.

===== ART-DIRECTION BRIEF =====
$Prompt
===== END BRIEF =====
"@
  }
  'task' {
    $Prompt = @"
You are an execution subagent for another AI assistant (Claude). Complete the brief below in the working directory.
Follow the numbered steps in order and run each step's acceptance check before moving on.
Do exactly what the brief says: do not skip steps, do not add unrequested features, do not touch anything listed as out of scope.
If a step cannot be completed as written, stop and report why instead of improvising.
Final reply: 1) per-step status (done / failed + reason), 2) files changed/created, 3) commands run for verification and their result, 4) anything left unfinished.

$Prompt
"@
  }
}

# --- argümanlar --------------------------------------------------------------
$common = @('--json', '--skip-git-repo-check')
if ($Model)  { $common += @('-m', $Model) }
if ($Effort) { $common += @('-c', "model_reasoning_effort=`"$Effort`"") }
if ($Schema) { $common += @('--output-schema', (Resolve-Path $Schema).Path) }
$imgArgs = @(); foreach ($img in $Images) { $imgArgs += @('-i', (Resolve-Path $img).Path) }

$sandbox = if ($Mode -in 'task', 'bulk' -and $Write) { 'workspace-write' } else { 'read-only' }

if ($Session) {
  $cmdArgs = @('exec', 'resume') + $common + $imgArgs + @('-c', "sandbox_mode=`"$sandbox`"", $Session, '-')
} elseif ($Mode -eq 'review') {
  $cmdArgs = @('exec', 'review') + $common
  if ($Uncommitted) { $cmdArgs += '--uncommitted' }
  if ($Base)        { $cmdArgs += @('--base', $Base) }
  if ($Commit)      { $cmdArgs += @('--commit', $Commit) }
  if ($Prompt)      { $cmdArgs += '-' }
} else {
  $cmdArgs = @('exec') + $common + $imgArgs + @('-s', $sandbox, '-C', $Cd, '-')
}

# --- çalıştır ----------------------------------------------------------------
$start = Get-Date
Push-Location $Cd
try {
  if ($Prompt) { $lines = $Prompt | & codex @cmdArgs 2>$null }
  else         { $lines = & codex @cmdArgs 2>$null }
  $exit = $LASTEXITCODE
} finally { Pop-Location }

$threadId = $null; $messages = @(); $errors = @(); $usage = $null
foreach ($l in $lines) {
  try { $e = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
  switch ($e.type) {
    'thread.started' { $threadId = $e.thread_id }
    'item.completed' { if ($e.item.type -eq 'agent_message' -and $e.item.text) { $messages += $e.item.text } }
    'turn.completed' { $usage = $e.usage }
    'turn.failed'    { $errors += ($e.error.message ?? ($e | ConvertTo-Json -Compress)) }
    'error'          { $errors += ($e.message ?? ($e | ConvertTo-Json -Compress)) }
  }
}
if (-not $threadId -and $Session) { $threadId = $Session }

$final = if ($messages.Count) { $messages[-1] } else { '' }
if ($final) { Write-Output $final }
if ($Out -and $Mode -ne 'image' -and $final) { Set-Content -Encoding utf8 -Path $Out -Value $final }

# --- image: generated_images/<thread_id>/ altından kopyala -------------------
$status = if ($exit -eq 0 -and -not $errors.Count) { 'ok' } else { 'error' }
if ($Mode -eq 'image' -and $threadId) {
  $dir = Join-Path $HOME ".codex\generated_images\$threadId"
  $imgs = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-5) } | Sort-Object LastWriteTime)
  if (-not $imgs.Count) {
    $status = 'error'; $errors += "Görsel üretilmedi ($dir boş)."
  } else {
    if (-not $Out) { $Out = Join-Path $Cd ("codex-image-{0:yyyyMMdd-HHmmss}.png" -f (Get-Date)) }
    $outDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Out))
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
    $base = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetFullPath($Out), $null).TrimEnd('.')
    $ext  = [System.IO.Path]::GetExtension($Out); if (-not $ext) { $ext = $imgs[0].Extension }
    for ($i = 0; $i -lt $imgs.Count; $i++) {
      $dest = if ($i -eq 0) { "$base$ext" } else { "$base-$($i+1)$ext" }
      # gerçekten raster görsel mi? (PNG/JPEG/WebP imzası) — SVG/HTML yedeğini reddet
      $hdr = [System.IO.File]::ReadAllBytes($imgs[$i].FullName)[0..11]
      $isImg = ($hdr[0] -eq 0x89 -and $hdr[1] -eq 0x50) -or ($hdr[0] -eq 0xFF -and $hdr[1] -eq 0xD8) -or
               ([System.Text.Encoding]::ASCII.GetString($hdr[8..11]) -eq 'WEBP')
      if (-not $isImg) { $status = 'error'; $errors += "Geçersiz görsel: $($imgs[$i].FullName)"; continue }
      Copy-Item $imgs[$i].FullName $dest -Force
      Write-Output "CODEX_IMAGE=$dest"
      Write-Output "CODEX_IMAGE_SOURCE=$($imgs[$i].FullName)"
    }
  }
}

foreach ($er in $errors) { Write-Output "CODEX_ERROR=$er" }
if ($usage) { Write-Output ("CODEX_TOKENS=in:{0} out:{1}" -f $usage.input_tokens, $usage.output_tokens) }
if ($threadId) { Write-Output "CODEX_THREAD_ID=$threadId" }
Write-Output "CODEX_STATUS=$status"
if ($status -ne 'ok') { exit 1 }
