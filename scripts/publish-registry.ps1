# Publish a released package version into the blook-project xmake registry.
#
# Flow (see docs/RELEASE.md for the full release contract):
#   1. repo publishes a GitHub Release tag vX.Y.Z with asset
#      <package>-<version>-windows-x64.zip (+ optional <asset>.sha256)
#   2. this script reads the release via `gh`, resolves asset name + sha256,
#   3. clones/updates blook-project/blook-xmake-repo, bumps
#      packages/<letter>/<package>/versions.txt ("<version> <sha256>"),
#   4. commits + pushes the registry update (no org secret needed: uses your gh auth).
#
# Examples:
#   # after tagging blook-kchannel v1.0.0
#   pwsh scripts/publish-registry.ps1 -Package blook-kchannel -Version 1.0.0
#
#   # dry run / local checks (no push), explicit sha (e.g. from CI)
#   pwsh scripts/publish-registry.ps1 -Package blook-kdu -Version 1.2.0 -Sha256 <64hex> -DryRun
#
#   # first publish of a new package: seed the manifest from the repo's xmake-package/ dir
#   pwsh scripts/publish-registry.ps1 -Package blook-drv -Version 1.0.0 -ManifestFile ..\blook-drv\xmake-package\xmake.lua
#
# Exit codes: 0 = published/already up to date, 1 = failure.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Repo,
    [string]$AssetName,
    [string]$Sha256,
    [string]$RegistryDir,
    [string]$RegistryRepo = 'blook-project/blook-xmake-repo',
    [string]$ManifestFile,
    [switch]$NoPush,
    [switch]$DryRun,
    [switch]$NoVerify,
    [string]$Xmake = 'xmake'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Step([string]$message) { Write-Host "==> $message" }
function Fail([string]$message) { Write-Host "ERROR: $message" -ForegroundColor Red; exit 1 }
function AssertGithubCli() {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail 'gh (GitHub CLI) not found in PATH' }
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'gh is not authenticated (run: gh auth login)' }
}
function AssertSemver([string]$v) {
    if ($v -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$') { Fail "version '$v' is not semver-ish (expected X.Y.Z, optional -pre/+build)" }
}
function NormalizeSha([string]$value) {
    $m = [regex]::Match($value, '(?i)([0-9a-f]{64})')
    if (-not $m.Success) { Fail "could not find a 64-hex sha256 in provided value" }
    return $m.Groups[1].Value.ToLowerInvariant()
}
function Get-VersionKey([string]$v) {
    # sort key: numeric X.Y.Z, pre-release sorts before release; fall back to string
    $core = $v
    $pre = ''
    $plus = $core.IndexOf('+')
    if ($plus -ge 0) { $core = $core.Substring(0, $plus) }
    $dash = $core.IndexOf('-')
    if ($dash -ge 0) { $pre = $core.Substring($dash + 1); $core = $core.Substring(0, $dash) }
    $parts = @($core.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    $nums = @()
    foreach ($p in $parts[0..2]) {
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { $n = 0 }
        $nums += $n
    }
    # release (no pre) sorts above pre-release of the same core
    $preKey = if ($pre -eq '') { '~' } else { $pre }
    return ('{0:D10}.{1:D10}.{2:D10}.{3}' -f $nums[0], $nums[1], $nums[2], $preKey)
}

if (-not $Repo) { $Repo = "blook-project/$Package" }
AssertSemver $Version
if ($Sha256) { $Sha256 = NormalizeSha $Sha256 }

AssertGithubCli

# --- 1. resolve release asset -------------------------------------------------
Step "release: $Repo v$Version"
$releaseJson = & gh release view "v$Version" -R $Repo --json tagName,isDraft,isPrerelease,assets 2>&1
if ($LASTEXITCODE -ne 0) { Fail "release v$Version not found in $Repo (publish the release first): $releaseJson" }
$release = $releaseJson | ConvertFrom-Json
if ($release.isDraft) { Fail "release v$Version is a draft; publish it before updating the registry" }
$assets = @($release.assets)
if ($assets.Count -eq 0) { Fail "release v$Version has no assets" }

$expectedAsset = "$Package-$Version-windows-x64.zip"
if ($AssetName) {
    $asset = $assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) { Fail "release v$Version has no asset '$AssetName' (assets: $($assets.name -join ', '))" }
} else {
    $asset = $assets | Where-Object { $_.name -eq $expectedAsset } | Select-Object -First 1
    if (-not $asset) { $asset = $assets | Where-Object { $_.name -like "$Package-$Version-*.zip" } | Select-Object -First 1 }
    if (-not $asset) { $asset = $assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1 }
    if (-not $asset) { Fail "release v$Version has no .zip asset (assets: $($assets.name -join ', '))" }
}
$AssetName = $asset.name
if ([int64]$asset.size -le 0) { Fail "asset '$AssetName' is empty (size=$($asset.size))" }
Step "asset: $AssetName ($([math]::Round([int64]$asset.size / 1KB, 1)) KiB)"

# --- 2. resolve sha256 --------------------------------------------------------
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('blook-registry-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$tmpRegistry = $null
try {
    if (-not $Sha256) {
        $shaAssetName = "$AssetName.sha256"
        $shaAsset = $assets | Where-Object { $_.name -eq $shaAssetName } | Select-Object -First 1
        if ($shaAsset) {
            Step "sha256: downloading $shaAssetName from the release"
            & gh release download "v$Version" -R $Repo -p $shaAssetName -D $tmpRoot --clobber 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "failed to download $shaAssetName" }
            $shaText = Get-Content -LiteralPath (Join-Path $tmpRoot $shaAssetName) -Raw
            $Sha256 = NormalizeSha $shaText
        } else {
            Step "sha256: no .sha256 asset, downloading $AssetName to hash it"
            & gh release download "v$Version" -R $Repo -p $AssetName -D $tmpRoot --clobber 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "failed to download $AssetName" }
            $Sha256 = (Get-FileHash -LiteralPath (Join-Path $tmpRoot $AssetName) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    Step "sha256: $Sha256"

    # --- 3. registry clone ----------------------------------------------------
    $cloneArgs = @('repo', 'clone', $RegistryRepo)
    if ($RegistryDir) {
        $RegistryDir = (Resolve-Path $RegistryDir).Path
        if (-not (Test-Path (Join-Path $RegistryDir '.git'))) { Fail "RegistryDir '$RegistryDir' is not a git repository" }
        $remotes = (& git -C $RegistryDir remote -v 2>&1 | Out-String)
        if ($remotes -notmatch [regex]::Escape($RegistryRepo)) {
            Fail "RegistryDir '$RegistryDir' does not have a remote pointing at $RegistryRepo"
        }
        Step "registry: using existing clone $RegistryDir"
    } else {
        $RegistryDir = Join-Path $tmpRoot 'blook-xmake-repo'
        Step "registry: cloning $RegistryRepo"
        & gh @cloneArgs $RegistryDir -- --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $RegistryDir '.git'))) { Fail "failed to clone $RegistryRepo" }
    }

    # keep the clone current (squash daily changes are fine; --ff-only avoids surprises)
    & git -C $RegistryDir pull --ff-only --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host 'WARN: git pull --ff-only failed; continuing with local state' -ForegroundColor Yellow }

    # --- 4. update package manifest/versions ----------------------------------
    $letter = $Package.Substring(0, 1).ToLowerInvariant()
    $pkgDir = Join-Path $RegistryDir "packages/$letter/$Package"
    $versionsPath = Join-Path $pkgDir 'versions.txt'
    $manifestPath = Join-Path $pkgDir 'xmake.lua'

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        if (-not $ManifestFile) {
            Fail "package '$Package' is not in the registry yet ($pkgDir). Add packages/$letter/$Package/xmake.lua first, or pass -ManifestFile <path to your xmake-package/xmake.lua>."
        }
        $ManifestFile = (Resolve-Path $ManifestFile).Path
        Step "registry: creating new package from $ManifestFile"
        New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
        Copy-Item -LiteralPath $ManifestFile -Destination $manifestPath
        Set-Content -LiteralPath $versionsPath -Value '# <version> <sha256>    # one published version per line; updated by scripts/publish-registry.ps1' -NoNewline:$false
    }
    if (-not (Test-Path -LiteralPath $versionsPath)) {
        Set-Content -LiteralPath $versionsPath -Value '# <version> <sha256>'
    }

    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    $expectedUrlTemplate = "https://github.com/$Repo/releases/download/v`$(version)/$Package-`$(version)-windows-x64.zip"
    if ($manifestText -notmatch [regex]::Escape("github.com/$Repo/releases/download/")) {
        Fail "manifest $manifestPath does not point at https://github.com/$Repo/releases/download/...; refusing to add version $Version (fix the manifest or pass -Repo)"
    }
    if ($manifestText -notmatch [regex]::Escape('$(version)')) {
        Fail "manifest $manifestPath does not use the `$(version) URL template; add_urls must be template-based"
    }

    # versions.txt: keep comment/blank lines, replace same version, sort ascending.
    $headerLines = New-Object System.Collections.Generic.List[string]
    $entries = @{}
    foreach ($line in (Get-Content -LiteralPath $versionsPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            if ($trimmed.StartsWith('#')) { $headerLines.Add($trimmed) | Out-Null }
            continue
        }
        if ($trimmed -match '^(\S+)\s+([0-9a-fA-F]{64})$') {
            $entries[$Matches[1]] = $Matches[2].ToLowerInvariant()
        } else {
            Write-Host "WARN: ignoring malformed versions.txt line: $trimmed" -ForegroundColor Yellow
        }
    }
    $alreadyPublished = $entries.ContainsKey($Version) -and $entries[$Version] -eq $Sha256
    if ($entries.ContainsKey($Version) -and -not $alreadyPublished) {
        Write-Host "NOTE: replacing existing $Version entry ($($entries[$Version]) -> $Sha256)" -ForegroundColor Yellow
    }
    $entries[$Version] = $Sha256

    $sorted = $entries.GetEnumerator() | Sort-Object { Get-VersionKey $_.Key }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($headerLines.Count -eq 0) { $lines.Add('# <version> <sha256>') | Out-Null } else { foreach ($h in $headerLines) { $lines.Add($h) | Out-Null } }
    foreach ($e in $sorted) { $lines.Add("$($e.Key) $($e.Value)") | Out-Null }
    $newVersionsText = ($lines -join "`n") + "`n"
    if (-not $DryRun) {
        [System.IO.File]::WriteAllText($versionsPath, $newVersionsText, (New-Object System.Text.UTF8Encoding($false)))
    }

    # --- 5. stage + commit (verification runs against the committed state) ----
    & git -C $RegistryDir add -A
    $status = (& git -C $RegistryDir status --porcelain 2>&1 | Out-String).Trim()
    if ($status -eq '') {
        Step 'registry: no changes (version already published with this sha256)'
        if ($DryRun) { Write-Host 'DRY RUN: nothing to push' }
        exit 0
    }
    $diff = (& git -C $RegistryDir diff --cached 2>&1 | Out-String)
    if ($DryRun) {
        Step 'DRY RUN: would commit these changes:'
        Write-Host $diff
        & git -C $RegistryDir reset --hard --quiet
        exit 0
    }
    $commitMessage = "registry: publish $Package $Version"
    & git -C $RegistryDir -c user.name='MicroBlock' -c user.email='66859419+std-microblock@users.noreply.github.com' commit -m $commitMessage --quiet
    if ($LASTEXITCODE -ne 0) { Fail 'git commit failed' }
    $commitSha = (& git -C $RegistryDir rev-parse --short HEAD | Out-String).Trim()

    # --- 6. optional install verification (rolls the commit back when red) ----
    if (-not $NoVerify) {
        Step 'verify: installing the published version from the local registry clone'
        $verifyDir = Join-Path $tmpRoot 'verify'
        New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
        $registryUrl = 'file:///' + ($RegistryDir -replace '\\', '/')
        $verifyProject = @"
add_rules("mode.release")
add_repositories("blook $registryUrl")
add_requires("$Package $Version")
target("verify")
    set_kind("binary")
    add_files("main.cpp")
    add_packages("$Package")
"@
        Set-Content -LiteralPath (Join-Path $verifyDir 'xmake.lua') -Value $verifyProject -Encoding utf8
        Set-Content -LiteralPath (Join-Path $verifyDir 'main.cpp') -Value 'int main() { return 0; }' -Encoding utf8
        Push-Location $verifyDir
        try {
            & $Xmake f -c -y -m release 2>&1 | Out-Null
            $cfgCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($cfgCode -ne 0) {
            & git -C $RegistryDir reset --hard HEAD~1 --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host 'WARN: could not roll back the verification commit' -ForegroundColor Yellow }
            Fail "install verification failed: xmake could not install $Package $Version (asset name/sha256 mismatch, unreadable manifest, or xmake error)"
        }
        Write-Host "   verified: $Package $Version installs from $expectedUrlTemplate"
    }

    # --- 7. push --------------------------------------------------------------
    if ($NoPush) {
        Step "registry: committed $commitSha locally (-NoPush)"
    } else {
        Step "registry: pushing $commitSha to $RegistryRepo"
        & git -C $RegistryDir push --quiet origin HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "git push failed (check access to $RegistryRepo)" }
        Step "registry: published $Package $Version ($commitSha)"
    }
    Write-Host ''
    Write-Host "package : $Package"
    Write-Host "version : $Version"
    Write-Host "repo    : $Repo"
    Write-Host "asset   : $AssetName"
    Write-Host "sha256  : $Sha256"
    Write-Host "url     : $expectedUrlTemplate"
    Write-Host "manifest: packages/$letter/$Package/xmake.lua"
    Write-Host "versions: packages/$letter/$Package/versions.txt"
    exit 0
} finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
