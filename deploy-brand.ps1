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
$Pages     = @(
  @{ File = "_brand\index.html";   Lang = "en"; Canonical = "https://oasislocal.github.io/"     },
  @{ File = "_brand\es\index.html"; Lang = "es"; Canonical = "https://oasislocal.github.io/es/" }
)

# ---------- 1. Source checks ----------
foreach ($p in $Pages) {
  if (-not (Test-Path -LiteralPath $p.File)) { Fail ("missing " + $p.File) }
}

# Every check below runs on both files. The two languages are written by hand and
# nothing generates them, so this gate is the only thing keeping them honest: a
# translation that quietly drifts is invisible on the page that still has the old
# version, and a broken link in the Spanish file costs a Spanish reader.
$docs = @{}
foreach ($p in $Pages) {
  $lang  = $p.Lang
  $where = $p.File
  $html  = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $p.File))
  $docs[$lang] = $html

  # A duplicate <title> is invalid HTML: the browser silently keeps the first, so
  # the page can look right in a screenshot and still ship the wrong title to a
  # search engine.
  $titles = ([regex]::Matches($html, "<title>")).Count
  if ($titles -ne 1) { Fail "$where : expected exactly one <title>, found $titles" }
  if ($html -notmatch ([regex]::Escape('rel="canonical" href="' + $p.Canonical + '"'))) {
    Fail "$where : canonical must be $($p.Canonical)"
  }
  if ($html -notmatch [regex]::Escape('<html lang="' + $lang + '"')) { Fail "$where : <html lang> must be $lang" }
  if ($html -notmatch "Content-Security-Policy") { Fail "$where : no Content-Security-Policy" }

  # hreflang: each file declares both languages and x-default points at the root.
  # Two URLs that do not acknowledge each other are worse than a single URL with no
  # hreflang at all, which is what this page used to be. Each one is checked with
  # its target, not just its presence: a self-referential alternate is the exact
  # mistake that survives a copy-paste between the two files.
  $alternates = @(
    @{ Lang = "en"; Href = "https://oasislocal.github.io/" },
    @{ Lang = "es"; Href = "https://oasislocal.github.io/es/" }
  )
  foreach ($alt in $alternates) {
    $needle = '<link rel="alternate" hreflang="' + $alt.Lang + '" href="' + $alt.Href + '">'
    if ($html -notmatch [regex]::Escape($needle)) {
      Fail "$where : missing or wrong hreflang $($alt.Lang) (expected $needle)"
    }
  }
  if ($html -notmatch [regex]::Escape('<link rel="alternate" hreflang="x-default" href="https://oasislocal.github.io/">')) {
    Fail "$where : x-default must point at the site root"
  }
  # The alternate locale has to be the other language. It is the kind of thing that
  # survives a copy-paste between the two files and then ships wrong.
  $expectLocale = if ($lang -eq "en") { "en_US" } else { "es_ES" }
  $expectAlt    = if ($lang -eq "en") { "es_ES" } else { "en_US" }
  if ($html -notmatch ([regex]::Escape('property="og:locale" content="' + $expectLocale + '"'))) {
    Fail "$where : og:locale must be $expectLocale"
  }
  if ($html -notmatch ([regex]::Escape('property="og:locale:alternate" content="' + $expectAlt + '"'))) {
    Fail "$where : og:locale:alternate must be $expectAlt"
  }

  # The whole point of the product's promise is that nothing is loaded from a third
  # party. A hyperlink is not a request: clicking "Source on GitHub" is navigation,
  # not a subresource, and neither is the canonical pointing at this same host.
  #
  # Each entry is parenthesised on purpose. Inside @(), PowerShell binds the comma
  # tighter than +, so the unparenthesised version silently concatenated the three
  # alternatives into one meaningless pattern: the array came out with a single
  # entry that never matched anything, and this check had been passing vacuously.
  $here = "oasislocal\.github\.io"
  $loads = @(
    ('src="https?://(?!' + $here + ')'),
    ('<link[^>]+rel="stylesheet"[^>]+href="https?://(?!' + $here + ')'),
    ('@import\s+(?:url\()?["'']?https?://(?!' + $here + ')')
  )
  if ($loads.Count -ne 3) { Fail "$where : the third-party check is malformed ($($loads.Count) patterns, expected 3)" }
  foreach ($pat in $loads) {
    if ($html -match $pat) { Fail "$where : loads a subresource from a third-party origin (match: $pat)" }
  }

  # Links into the product must carry the language prefix that matches the file.
  # Without it a Spanish reader lands on the English page, which is exactly what
  # check_lang.py exists to prevent on the product side. The bare prefix is the
  # product home and is checked as one of these, because the product is served
  # from a subpath and a link to the bare root would leave the site entirely.
  $prefix = if ($lang -eq "es") { "/O.A.S.I.S./es/" } else { "/O.A.S.I.S./" }
  foreach ($needle in @($prefix, ($prefix + "blog/"), ($prefix + "glossary/"), ($prefix + "download.html"))) {
    if ($html -notmatch [regex]::Escape('href="' + $needle + '"')) { Fail "$where : missing product link $needle" }
  }
  # The Max waitlist CTA has to survive with its anchor, or the landing describes
  # an edition the reader has no way to join.
  if ($html -notmatch [regex]::Escape('href="' + $prefix + '#wl-form"')) {
    Fail "$where : the Max waitlist link with its #wl-form anchor is missing"
  }
  # The language switch has to reach the other file, not itself.
  $other = if ($lang -eq "en") { "/es/" } else { "/" }
  if ($html -notmatch [regex]::Escape('href="' + $other + '"')) { Fail "$where : the language switch does not link to $other" }
}

# Parity: the same landmarks in both files, so one language cannot quietly lose a
# section. Compared as tag names because a missing <section> is the failure that
# actually costs a reader something.
function Get-Landmarks($html) {
  $out = @()
  foreach ($m in [regex]::Matches($html, "<(section|main|footer|h1|h2|table)\b")) { $out += $m.Groups[1].Value }
  return $out
}
$enMarks = Get-Landmarks $docs["en"]
$esMarks = Get-Landmarks $docs["es"]
if (($enMarks -join ",") -ne ($esMarks -join ",")) {
  Fail ("the two languages do not have the same structure.`n  en: " + ($enMarks -join ",") +
        "`n  es: " + ($esMarks -join ","))
}
# The catalogue is the part of this page most likely to rot, so its entries are
# named explicitly rather than counted.
foreach ($name in @("Personal", "Max")) {
  foreach ($lang in @("en", "es")) {
    if ($docs[$lang] -notmatch [regex]::Escape(">" + $name + "<")) { Fail "$lang : the catalogue is missing the $name edition" }
  }
}
# Max is not on sale, and the page says so in words. If those words ever go, the
# page starts implying a purchase that does not exist.
#
# Anchored on the <b> element on purpose. An earlier version searched for the bare
# phrase and matched a CSS comment in the file that happened to quote it, so the
# check passed even with the label removed from the page. Only the rendered
# element counts.
if ($docs["en"] -notmatch [regex]::Escape("<b>Not available yet</b>")) {
  Fail "en : the Max edition is not marked as not available yet"
}
if ($docs["es"] -notmatch "<b>Todav\w+a no disponible</b>") {
  Fail "es : the Max edition is not marked as not available yet"
}

# No place names, ever. A product sold on keeping your data on your own machine
# should not start by handing over where its author is, and "Galicia" appeared in
# five places on this landing before it was removed: the description, og, twitter,
# the section and the footer. Checked across the whole file, comments included, so
# a re-introduction in a caption is caught as well as one in the prose.
#
# Written as substrings that do not need any accent escaping, so the pattern is
# plain ASCII and there is nothing here that can silently fail to compile. "Coru"
# covers both "Coruña" and "Coruna"; "Andaluc" covers "Andalucía"/"Andalucia".
$places = @(
  "Galicia", "Coru", "Santiago de Compostela", "Vigo", "Lugo", "Ourense",
  "Pontevedra", "Gipuzkoa", "Bizkaia", "Barcelona", "Madrid", "Valencia",
  "Euskadi", "Catalunya", "Catalonia", "Andaluc", "Canary", "Canarias"
)
$n_tilde = [char]0xF1
# Parenthesised for the same reason as $loads above, and the one below it: inside
# @(), the comma binds tighter than +, so an unparenthesised "a" + $x + "b" splits
# into fragments and the list silently loses its elements. That is how this very
# check first reported a country called "Espa".
$countries = @(
  ("Spain"),
  ("Espa" + $n_tilde + "a")
)
if ($countries.Count -ne 2) { Fail "the country check is malformed ($($countries.Count) entries, expected 2)" }
if ($places.Count -ne 18) { Fail "the place check is malformed ($($places.Count) entries, expected 18)" }
foreach ($lang in @("en", "es")) {
  foreach ($place in $places) {
    if ($docs[$lang] -match [regex]::Escape($place)) {
      Fail ($lang + " : the page names a place (" + $place + "), which a privacy project should not publish")
    }
  }
  foreach ($country in $countries) {
    if ($docs[$lang] -match [regex]::Escape($country)) {
      Fail ($lang + " : the page names a country (" + $country + ")")
    }
  }
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
  # Both languages go out in the same commit. Publishing the English and leaving
  # the Spanish on the previous deploy is the kind of half-release that looks
  # fine locally and serves a stale page to half the visitors.
  foreach ($p in $Pages) {
    $dest = Join-Path $wt $p.Out
    $dir  = Split-Path -Parent $dest
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $p.File) -Destination $dest -Force
  }
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
#
# Both addresses are probed, each for the word that can only be in its own
# language, so a deploy that publishes the English and loses the Spanish fails
# here instead of passing on a 200 that means nothing.
$probes = @(
  @{ Url = "https://oasislocal.github.io/";     Marker = "The oasis is on your own PC." },
  @{ Url = "https://oasislocal.github.io/es/";  Marker = "El oasis est" }
)
$deadline = (Get-Date).AddMinutes(4)
$pending  = $probes
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
  $still = @()
  foreach ($probe in $pending) {
    $tmpBody = [System.IO.Path]::GetTempFileName()
    try {
      $code = & curl.exe -s -L --max-time 25 -o $tmpBody -w "%{http_code}" $probe.Url
      $body = if (Test-Path -LiteralPath $tmpBody) { [System.IO.File]::ReadAllText($tmpBody) } else { "" }
      $n = 0; if ($code -match '^\d+$') { $n = [int]$code }
      if ($n -eq 200 -and $body.Contains($probe.Marker)) {
        Write-Host ("  OK  " + $probe.Url) -ForegroundColor Green
      } else {
        Write-Host ("  aun no: " + $probe.Url + " (HTTP " + $n + ")") -ForegroundColor DarkGray
        $still += $probe
      }
    } finally {
      Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
    }
  }
  $pending = $still
  if ($pending.Count -gt 0) { Start-Sleep -Seconds 20 }
}

if ($pending.Count -gt 0) {
  foreach ($probe in $pending) { Write-Host ("  sin servir: " + $probe.Url) -ForegroundColor Red }
  Write-Host "FALLO: alguna direccion no sirve la pagina de marca tras 4 minutos. El commit se subio; Pages sigue reconstruyendo o no esta habilitado." -ForegroundColor Red
  exit 1
}

Write-Host "BRAND DEPLOY DONE: las dos direcciones sirven" -ForegroundColor Green
exit 0
