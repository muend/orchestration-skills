<#
.SYNOPSIS
  Installs the orchestration skill set into Claude Code's user folders (~/.claude/skills, ~/.claude/agents).

.EXAMPLE
  pwsh -File install.ps1            # copy (overwrites existing files with the same name)
  pwsh -File install.ps1 -Link      # symlink instead, so `git pull` updates the installed skills
  pwsh -File install.ps1 -Check     # only report which external CLIs are available
#>
[CmdletBinding()]
param([switch]$Link, [switch]$Check)

$ErrorActionPreference = 'Stop'
$root   = $PSScriptRoot
$claude = Join-Path $HOME '.claude'

function Test-Cli($name, $hint) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { Write-Host "  [ok]      $name -> $($c.Source)" } else { Write-Host "  [missing] $name  ($hint)" }
}

Write-Host "External lanes:"
Test-Cli codex 'npm i -g @openai/codex ; codex login   (needs >= 0.167 for GPT-6.x)'
Test-Cli agy   'install Google Antigravity and sign in once (provides the agy CLI for Gemini)'
Test-Cli pwsh  'PowerShell 7 is required by the bridge scripts'
if ($Check) { return }

$targets = @()
Get-ChildItem (Join-Path $root 'skills') -Directory | ForEach-Object {
  $targets += [pscustomobject]@{ Src = $_.FullName; Dst = Join-Path $claude "skills\$($_.Name)"; Dir = $true }
}
Get-ChildItem (Join-Path $root 'agents') -File -Filter *.md | ForEach-Object {
  $targets += [pscustomobject]@{ Src = $_.FullName; Dst = Join-Path $claude "agents\$($_.Name)"; Dir = $false }
}

foreach ($t in $targets) {
  New-Item -ItemType Directory -Force (Split-Path $t.Dst) | Out-Null
  if (Test-Path $t.Dst) { Remove-Item -Recurse -Force $t.Dst }
  if ($Link) { New-Item -ItemType SymbolicLink -Path $t.Dst -Target $t.Src | Out-Null }
  else       { Copy-Item -Recurse -Force $t.Src $t.Dst }
  Write-Host "installed $($t.Dst)"
}
Write-Host "`nDone. Start a new Claude Code session so the agents are loaded."
