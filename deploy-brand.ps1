<#
.SYNOPSIS
  Publish the brand page to https://oasislocal.github.io/ (the site root).
.DESCRIPTION
  The root of oasislocal.github.io is the *user/organisation* site, and
  https://oasislocal.github.io/O.A.S.I.S./ is the *project* site. They are two
  different repositories, which is why the product deploy in sync-web.ps1 cannot
  put anything at the root:

    https://github.com/OASISLocal/O.A.S.I.S.          -> serves /O.A.S.I.S./
    https://github.com/OASISLocal/OASISLocal.github.io -> serves /

  The source lives in _brand/ inside this repository so it is versioned and
  reviewed with everything else. The leading underscore is not cosmetic: Jekyll
  ignores underscore-prefixed directories, so the brand page is never published
  on the product site and no change to sync-web.ps1 is needed to keep it out.

  Deploy is a snapshot commit on the brand repository's github-pages branch via a
  temp worktree, the same approach as the product, so its history stays linear.

  This script refuses to run if the brand repository does not exist yet, because
  the failure it can prevent (clobbering the wrong repository) is worse than the
  work it does.
.EXAMPLE
  .\deploy-brand.ps1
  .\deploy-brand.ps1 -Message "Brand page: first version"
#>
param(
  [string]$Message = ""
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Fail($msg) { Write-Host "BRAND DEPLOY ABORTED: $msg" -ForegroundColor Red; exit 1 }

$BrandRepo = "https://github.com/OASISLocal/OASISLocal.github.io.git"
$Source    = Join-Path $PSScriptRoot "_brand\index.html"

# ---------- 1. Source checks ----------
if (-not (Test-Path -LiteralPath $Source)) { Fail "missing _brand\index.html" }

$html = [System.IO.File]::ReadAllText($Source)

# A duplicate <title> is invalid HTML: the browser silently keeps the first, so
# the page can look right in a screenshot and still ship the wrong title to a
# search engine. Cheap to catch here.
$titles = ([regex]::Matches($html, "<title>")).Count
if ($titles -ne 1) { Fail "expected exactly one <title>, found $titles" }
if ($html -notmatch 'rel="canonical" href="https://oasislocal\.github\.io/"') {
  Fail "the canonical must be the site root, https://oasislocal.github.io/"
}
if ($html -notmatch "Content-Security-Policy") { Fail "no Content-Security-Policy in the brand page" }
# The whole point of the product's promise is that nothing is loaded from a third
# party. A stray CDN reference here would quietly break it on the one page that
# states it. A hyperlink is not a request: clicking "Source on GitHub" is
# navigation, not a subresource, and neither is the canonical pointing at this
# same host. So only loads are checked, and this host is allowed.
$here = "oasislocal\.github\.io"
$loads = @(
  'src="https?://(?!' + $here + ')',
  '<link[^>]+rel="stylesheet"[^>]+href="https?://(?!' + $here + ')',
  '@import\s+(?:url\()?["'']?https?://(?!' + $here + ')'
)
foreach ($p in $loads) {
  if ($html -match $p) { Fail "the brand page loads a subresource from a third-party origin (match: $p); this site loads nothing from one" }
}

# Links into the product have to point at the subpath, not at the root.
foreach ($needle in @('href="/O.A.S.I.S./"', 'href="/O.A.S.I.S./blog/"', 'href="/O.A.S.I.S./glossary/"')) {
  if ($html -notmatch [regex]::Escape($needle)) { Fail "missing product link $needle" }
}

Write-Host "== checks OK ==" -ForegroundColor Green

# Past this point the outcome is decided by git's exit code, not by whether git
# wrote to stderr. This has to be set before the first git call, not after the
# repository check: PowerShell turns a native command's stderr into a
# terminating error while the preference is "Stop", and even 2>$null does not
# stop the error record from being written. git prints a routine "Repository not
# found" on the probe below and an LF/CRLF notice on every add, and treating
# those as failures is how the product's own Pages check came to report a healthy
# site as dead.
$ErrorActionPreference = "Continue"

# ---------- 2. Repository must exist ----------
# git ls-remote fails on a repository that does not exist and on one we cannot
# reach, which are different problems, so the message covers both.
& git ls-remote --exit-code $BrandRepo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "No se puede llegar a $BrandRepo" -ForegroundColor Yellow
  Write-Host "Crea ese repositorio una sola vez (es el sitio de usuario de la organizacion):" -ForegroundColor Yellow
  Write-Host "  1. New repository, nombre exacto: OASISLocal.github.io, dentro de OASISLocal" -ForegroundColor Yellow
  Write-Host "  2. Settings > Pages > Source: rama 'github-pages' ( aun no existe: creala con un README )" -ForegroundColor Yellow
  Write-Host "  3. Vuelve a ejecutar este script" -ForegroundColor Yellow
  exit 1
}

# ---------- 3. Snapshot commit ----------
# The repository URL is used directly instead of a named remote on purpose: a
# remote would have to exist before this script could run, and a leftover "brand"
# remote pointing at a repository that may not exist yet is state nobody can see
# from the log.
& git fetch $BrandRepo github-pages 2>&1 | Out-Null
$haveBranch = ($LASTEXITCODE -eq 0)
if (-not $haveBranch) {
  Write-Host "La rama github-pages no existe todavia: se creara en el primer despliegue." -ForegroundColor DarkGray
}

$wt = Join-Path ([System.IO.Path]::GetTempPath()) "oasis-brand-wt"
if (Test-Path $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
& git worktree prune
if ($haveBranch) { & git worktree add --detach $wt FETCH_HEAD 2>&1 | Out-Null }
if (-not $haveBranch -or $LASTEXITCODE -ne 0) {
  # First deploy: there is no branch to check out, so build the tree from main.
  & git worktree add --detach $wt main 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "worktree setup failed" }
}

try {
  Push-Location -LiteralPath $wt
  & git rm -r -q . 2>&1 | Out-Null
  Copy-Item -LiteralPath $Source -Destination (Join-Path $wt "index.html") -Force
  # Static, no front matter, and nothing for Jekyll to do: serving it verbatim is
  # both correct and faster.
  New-Item -ItemType File -Path (Join-Path $wt ".nojekyll") -Force | Out-Null
  & git add -A
  if (-not $Message) { $Message = "Brand page " + (Get-Date -Format "yyyy-MM-dd HH:mm") }
  & git commit -q -m $Message
  if ($LASTEXITCODE -ne 0) { Fail "nothing to commit or the commit failed" }
  & git push $BrandRepo HEAD:github-pages
  if ($LASTEXITCODE -ne 0) { Fail "push to the brand repository failed" }
} finally {
  Pop-Location
  & git worktree remove --force $wt 2>&1 | Out-Null
}

# ---------- 4. Verify ----------
# curl.exe and not Invoke-WebRequest: the product baseurl ends in a dot and .NET
# normalises that segment away, which is what made the product's own Pages check
# report a dead site that was serving fine. The root has no dot, but the same
# helper is used here so the two do not drift apart again.
$url = "https://oasislocal.github.io/"
foreach ($attempt in 1..8) {
  $tmpBody = [System.IO.Path]::GetTempFileName()
  try {
    $code = & curl.exe -s -L --max-time 25 -o $tmpBody -w "%{http_code}" $url
    $body = if (Test-Path -LiteralPath $tmpBody) { [System.IO.File]::ReadAllText($tmpBody) } else { "" }
    $n = 0; if ($code -match '^\d+$') { $n = [int]$code }
    if ($n -eq 200 -and $body.Contains("O.A.S.I.S.")) {
      Write-Host "BRAND DEPLOY DONE: $url (intento $attempt/8)" -ForegroundColor Green
      exit 0
    }
    Write-Host "  aun no sirve: HTTP $n (intento $attempt/8)" -ForegroundColor DarkGray
  } finally {
    Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
  }
  if ($attempt -lt 8) { Start-Sleep -Seconds 20 }
}

Write-Host "FALLO: $url no sirve la pagina de marca tras 8 intentos. El commit se subio; Pages sigue reconstruyendo o no esta habilitado." -ForegroundColor Red
exit 1
