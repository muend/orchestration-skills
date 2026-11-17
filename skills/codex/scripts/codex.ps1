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
    CODEX_LIMIT_BEFORE / CODEX_LIMIT_AFTER=5h:<%> week:<%>   (abonelik limiti, oturum günlüğünden)
    CODEX_STATUS=ok|error|blocked|limit|dryrun   (exit 0 | 1 | 3 | 4 | 0)
  Her çalıştırma ~/.claude/orchestration/ledger.jsonl defterine bir satır yazar.

  Keşif -> yargı (limit ekonomisi):
  pwsh -File codex.ps1 -Mode scout -Cd C:\proj -PromptFile sorular.md -Out pack.md
  pwsh -File codex.ps1 -Mode judge -Cd C:\proj -PromptFile karar.md -Pack pack.md -Out karar-cevap.md
#>
[CmdletBinding()]
param(
  [ValidateSet('ask', 'scout', 'judge', 'opinion', 'image', 'task', 'bulk', 'review')]
  [string]$Mode = 'ask',
  [string]$Prompt,
  [string]$PromptFile,
  [string]$Model,                       # örn. gpt-6.2-sol | gpt-6.2-astra | gpt-6.1-terra | gpt-6-luna (6.2-luna/terra yok) ; boşsa config varsayılanı
  [ValidateSet('', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')]  # kullanıcı kuralı: medium/high; xhigh+ yalnız zorunluysa
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
  [int]$TimeoutSec = 1800,
  [string[]]$Pack,                      # kanıt paketi dosya(ları): brief'e "Evidence pack" olarak eklenir (judge'da zorunlu)
  [int]$MaxExtraFiles = 6,              # judge: paket dışında açılabilecek en fazla dosya
  [string]$EffortReason,                # xhigh için zorunlu gerekçe (deftere yazılır)
  [switch]$UserApproved,                # max/ultra veya limit eşiği aşımı için kullanıcının açık onayı
  [switch]$Force,                       # limit korumasını atla (yalnız kullanıcı isteyince)
  [switch]$DryRun,                      # codex'i çağırmadan son prompt'u, argümanları ve koruma kararını göster
  [string]$Lane                         # defterde görünecek kısa kol adı (ör. G1-guvenlik)
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

# --- yardımcılar: abonelik limiti ve maliyet defteri ------------------------
#   Codex her oturum dosyasına (~/.codex/sessions/Y/M/D/rollout-*.jsonl) token_count olaylarıyla birlikte
#   rate_limits yazar: primary = 5 saatlik pencere, secondary = haftalık pencere (used_percent).
function Get-CodexLimit {
  $root = Join-Path $HOME '.codex\sessions'
  if (-not (Test-Path $root)) { return $null }
  # Not: Windows açık tutulan dosyanın LastWriteTime'ını geç günceller; çalışan kolları kaçırmamak için
  # bugünün ve dünün tüm oturumları taranır, en yeni olay zaman damgası kazanır.
  $days = @((Get-Date), (Get-Date).AddDays(-1)) | ForEach-Object { Join-Path (Join-Path (Join-Path $root $_.ToString('yyyy')) $_.ToString('MM')) $_.ToString('dd') }
  $files = @($days | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Filter 'rollout-*.jsonl' -File })
  if (-not $files.Count) { $files = Get-ChildItem $root -Recurse -Filter 'rollout-*.jsonl' -File | Sort-Object { $_.FullName } -Descending | Select-Object -First 3 }
  $best = $null; $bestTs = [datetime]::MinValue
  foreach ($f in $files) {
    $tail = @(Get-Content -LiteralPath $f.FullName -Tail 400 -Encoding utf8 -ErrorAction SilentlyContinue)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
      if ($tail[$i] -notlike '*"rate_limits"*') { continue }
      try { $e = $tail[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      $rl = $e.payload.rate_limits
      if (-not ($rl -and $rl.primary)) { continue }   # bazı token_count satırlarında rate_limits null
      $ts = [datetime]$e.timestamp   # ConvertFrom-Json ISO'yu DateTime'a çevirir; metin karşılaştırma yanlış olur
      if ($ts -gt $bestTs) { $best = $rl; $bestTs = $ts }
      break
    }
  }
  if (-not $best) { return $null }
  # Kayıt sıfırlanmadan önce yazılmışsa (sonra hiç Codex çağrısı yoksa) değer bayattır: sıfırlanma zamanı geçen pencere %0.
  $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $five = [double]$best.primary.used_percent; $week = [double]$best.secondary.used_percent
  if ($best.primary.resets_at -and [long]$best.primary.resets_at -le $nowUnix) { $five = 0 }
  if ($best.secondary.resets_at -and [long]$best.secondary.resets_at -le $nowUnix) { $week = 0 }
  [pscustomobject]@{ FiveHour = $five; Weekly = $week
                     Plan = $best.plan_type; At = $bestTs.ToString('o') }
}
function Write-Ledger([hashtable]$rec) {
  try {
    $dir = Join-Path $HOME '.claude\orchestration'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $rec.ts = (Get-Date).ToString('o'); $rec.family = 'codex'
    Add-Content -Encoding utf8 -LiteralPath (Join-Path $dir 'ledger.jsonl') -Value ($rec | ConvertTo-Json -Compress -Depth 4)
  } catch { }
}

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
#   execution/image -> gpt-6.2-sol (brief'i harfiyen uygular)
#   opinion         -> gpt-6.2-astra (peer / farklı açı)
#   bulk            -> gpt-6-luna  (ucuz, mekanik toplu iş)
#   scout           -> gpt-6.2-sol   (geniş okuma -> kanıt paketi; yargı yok)
#   judge           -> gpt-6.2-astra (yalnız kanıt paketi üzerinden en zor yargı)
$laneModel  = @{ ask = 'gpt-6.2-sol'; scout = 'gpt-6.2-sol'; judge = 'gpt-6.2-astra'; task = 'gpt-6.2-sol'; image = 'gpt-6.2-sol'; review = 'gpt-6.2-sol'; opinion = 'gpt-6.2-astra'; bulk = 'gpt-6-luna' }
$laneEffort = @{ ask = 'medium'; scout = 'medium'; judge = 'high'; task = 'medium'; image = 'high'; review = 'high'; opinion = 'high'; bulk = 'low' }
if (-not $Model)  { $Model  = $laneModel[$Mode] }
if (-not $Effort) { $Effort = $laneEffort[$Mode] }

# --- kanıt paketi -------------------------------------------------------------
if ($Mode -eq 'judge' -and -not $Pack -and -not $Session) {
  Write-Output "CODEX_ERROR=judge modu -Pack <kanıt paketi> ister (önce scout / researcher / gemini digest ile paket hazırla)"; Write-Output "CODEX_STATUS=error"; exit 2
}
if ($Pack -and -not $Session) {
  $packText = foreach ($pf in $Pack) { "### Pack file: $(Split-Path -Leaf $pf)`n" + (Get-Content -Raw -Encoding utf8 -LiteralPath $pf) }
  $Prompt = "$Prompt`n`n===== EVIDENCE PACK (prepared by a scout lane; path:line excerpts) =====`n$($packText -join "`n`n")`n===== END EVIDENCE PACK ====="
}

# Yargı/yürütme cevaplarının sonu: GPT-6.2 Astra bilinen engelleri daha sık atlıyor (system card) -> açık bölüm zorunlu.
$footer = @"

Before you finish, verify that your answer fully covers what was asked. End your final answer with two short sections:
## Obstacles / not verified  (anything you could not check, run, open or confirm; tools or files that failed; "none" only if truly none)
## Assumptions  (reversible assumptions you made to keep going)
"@

# --- prompt hazırlığı -------------------------------------------------------
switch ($Mode) {
  'scout' {
    $Prompt = @"
You are a scout lane for another AI assistant (Claude). Your only job is to collect evidence; a stronger model judges it later.
Read what the brief points to and return an EVIDENCE PACK: for each question in the brief, the relevant facts as short
verbatim excerpts with path:line (or URL), grouped by question. No recommendations, no verdicts.
Keep the pack under ~8,000 words: prefer the decisive lines over whole files; note where more exists ("see path:120-180").
Do not modify any files. End with "## Gaps" listing what you looked for and could not find.

$Prompt
"@
  }
  'judge' {
    $Prompt = @"
You are consulted as a senior peer by another AI assistant (Claude) for a hard, high-stakes judgment.
Work from the evidence pack below. You may open at most $MaxExtraFiles additional files, only where the pack is insufficient for
a specific point; name each file and why before opening it. Do not re-explore the repository broadly. Do not modify files.
Disagree with the framing when the evidence says so. Give: verdict, the argument with pointers (path:line from the pack),
risks, and what would change your mind.

$Prompt
$footer
"@
  }
  'opinion' {
    $Prompt = @"
You are consulted as an independent peer reviewer by another AI assistant (Claude).
Do not just confirm. Look for what may be missing, wrong, or a better angle; disagree on evidence.
Structure: 1) your own read of the problem, 2) risks/blind spots, 3) alternatives worth considering, 4) your recommendation.
Do not modify any files.

$Prompt
$footer
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
You are an execution subagent for another AI assistant (Claude), working like a colleague who knows this project.
Complete the brief below in the working directory and keep going until it is done; do not stop to offer the work or ask
about routine decisions. Make reasonable, reversible assumptions and state them. Stop only if you are concretely blocked or
before anything destructive or irreversible. Stay inside the brief: no unrequested features, nothing listed as out of scope.
Run the brief's acceptance checks; do not trust a tool's "Done" without checking the result.
Final reply: 1) status per requirement (done / failed + reason), 2) files changed/created, 3) verification commands and results,
4) anything left unfinished.

$Prompt
$footer
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

# --- korumalar: düşünme seviyesi ve abonelik limiti -------------------------
#   Kullanıcı kuralı (2026-11-17): medium/high. xhigh yalnız gerekçeyle; max/ultra yalnız açık onayla.
#   Limit ekonomisi: Astra limiti hızlı yer. 5 saatlik pencere %60+ iken Astra, %85+ iken her Codex kolu durur.
$block = $null
if ($Effort -eq 'xhigh' -and -not $EffortReason -and -not $UserApproved) { $block = "xhigh için -EffortReason '<neden gerekli>' ver (kural: medium/high)" }
if ($Effort -in 'max', 'ultra' -and -not $UserApproved) { $block = "$Effort yalnız kullanıcının açık onayıyla (-UserApproved)" }
$limBefore = Get-CodexLimit
if (-not $block -and $limBefore -and -not $Force -and -not $UserApproved) {
  if ($limBefore.FiveHour -ge 85 -or $limBefore.Weekly -ge 90) { $block = "limit eşiği: 5 saatlik %$($limBefore.FiveHour), haftalık %$($limBefore.Weekly); sıfırlanmayı bekle veya Claude/Gemini koluna yönlendir" }
  elseif ($Model -like '*astra*' -and ($limBefore.FiveHour -ge 60 -or $limBefore.Weekly -ge 75)) { $block = "Astra limit eşiği: 5 saatlik %$($limBefore.FiveHour), haftalık %$($limBefore.Weekly); gpt-6.2-sol kullan veya sıfırlanmayı bekle" }
}
if ($limBefore) { Write-Output ("CODEX_LIMIT_BEFORE=5h:{0}% week:{1}% plan:{2}" -f $limBefore.FiveHour, $limBefore.Weekly, $limBefore.Plan) }
if ($block) {
  Write-Output "CODEX_BLOCKED=$block"; Write-Output "CODEX_STATUS=blocked"
  Write-Ledger @{ lane = $Lane; mode = $Mode; model = $Model; effort = $Effort; status = 'blocked'; reason = $block }
  exit 3
}
if ($DryRun) {
  Write-Output "CODEX_DRYRUN=codex $($cmdArgs -join ' ')"
  Write-Output "----- PROMPT ($($Prompt.Length) karakter) -----"; Write-Output $Prompt
  Write-Output "CODEX_STATUS=dryrun"; exit 0
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

$errors = @($errors | Select-Object -Unique)
foreach ($er in $errors) { Write-Output "CODEX_ERROR=$er" }
if ($errors -match 'usage limit|rate limit|429|limit reached') { $status = 'limit' }
if ($usage) { Write-Output ("CODEX_TOKENS=in:{0} cached:{1} out:{2}" -f $usage.input_tokens, $usage.cached_input_tokens, $usage.output_tokens) }
$limAfter = Get-CodexLimit
if ($limAfter) { Write-Output ("CODEX_LIMIT_AFTER=5h:{0}% week:{1}%" -f $limAfter.FiveHour, $limAfter.Weekly) }
Write-Ledger @{ lane = $Lane; mode = $Mode; model = $Model; effort = $Effort; effort_reason = $EffortReason; status = $status
  seconds = [int]((Get-Date) - $start).TotalSeconds; thread = $threadId; out = $Out
  tokens_in = $usage.input_tokens; tokens_cached = $usage.cached_input_tokens; tokens_out = $usage.output_tokens
  limit5h_before = $limBefore.FiveHour; limit5h_after = $limAfter.FiveHour; week_before = $limBefore.Weekly; week_after = $limAfter.Weekly }
if ($threadId) { Write-Output "CODEX_THREAD_ID=$threadId" }
Write-Output "CODEX_STATUS=$status"
if ($status -eq 'limit') { Write-Output "CODEX_HINT=limit doldu; sıfırlanınca -Session $threadId ile kaldığı yerden sürdür"; exit 4 }
if ($status -ne 'ok') { exit 1 }
