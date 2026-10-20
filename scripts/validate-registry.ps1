# Validate every package manifest in the blook-project xmake registry.
#
# Checks (always):
#   * repo skeleton files exist (README/LICENSE/docs)
#   * packages/<first-letter>/<package>/ layout is correct
#   * every manifest is a `package("<name>")` with the canonical release URL template:
#       https://github.com/blook-project/<name>/releases/download/v$(version)/<name>-$(version)-windows-x64.zip
#   * `add_versionfiles("versions.txt")` is used and versions.txt is well formed
#     ("<semver> <sha256>", lowercase hex, unique, sorted)
#
# Optional:
#   -WithXmake      parse each manifest with xmake's own package loader
#   -CheckAssets    HEAD every published release asset URL (network) and optionally
#                   compare the sibling .sha256 asset with versions.txt
#
# Usage:
#   pwsh ./scripts/validate-registry.ps1 [-WithXmake] [-CheckAssets]
# Exit code: 0 = OK, 1 = validation failed.

[CmdletBinding()]
param(
    [string]$RegistryRoot,
    [switch]$WithXmake,
    [switch]$CheckAssets,
    [string]$Xmake = 'xmake'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RegistryRoot) {
    $RegistryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$RegistryRoot = (Resolve-Path $RegistryRoot).Path

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$checked = 0
$versionsChecked = 0
$urlsChecked = 0

function Fail([string]$message) {
    $script:errors.Add($message) | Out-Null
}

function Warn([string]$message) {
    $script:warnings.Add($message) | Out-Null
}

Write-Host "== registry root: $RegistryRoot"

foreach ($required in @('README.md', 'LICENSE', 'docs/CI-WDK.md', 'docs/RELEASE.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RegistryRoot $required))) {
        Fail "missing required file: $required"
    }
}

$packagesRoot = Join-Path $RegistryRoot 'packages'
if (-not (Test-Path -LiteralPath $packagesRoot)) {
    Fail 'missing packages/ directory'
}

$packageDirs = @()
if (Test-Path -LiteralPath $packagesRoot) {
    $packageDirs = Get-ChildItem -LiteralPath $packagesRoot -Directory |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Directory |
                ForEach-Object { [pscustomobject]@{ Letter = $_.Parent.Name; Name = $_.Name; Dir = $_.FullName } }
        } | Sort-Object Letter, Name
}

if ($packageDirs.Count -eq 0) {
    Fail 'no packages found under packages/<letter>/<package>/'
}

# xmake manifest parse helper: needs a project dir to run `xmake l`.
$xmakeTmp = $null
if ($WithXmake) {
    $xmakeTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('blook-registry-validate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $xmakeTmp | Out-Null
    Set-Content -LiteralPath (Join-Path $xmakeTmp 'xmake.lua') -Value 'set_project("blook-registry-validate")' -Encoding utf8
}

try {
    foreach ($pkg in $packageDirs) {
        $checked++
        $name = $pkg.Name
        $dir = $pkg.Dir
        $expectedLetter = $name.Substring(0, 1).ToLowerInvariant()
        if ($pkg.Letter -ne $expectedLetter) {
            Fail "${name}: package directory must live under packages/$expectedLetter/ (found packages/$($pkg.Letter)/)"
        }

        $manifestPath = Join-Path $dir 'xmake.lua'
        $versionsPath = Join-Path $dir 'versions.txt'
        if (-not (Test-Path -LiteralPath $manifestPath)) { Fail "${name}: missing xmake.lua"; continue }
        if (-not (Test-Path -LiteralPath $versionsPath)) { Fail "${name}: missing versions.txt"; continue }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw
        if ($manifest -notmatch ('package\(\s*"' + [regex]::Escape($name) + '"\s*\)')) {
            Fail "${name}: xmake.lua does not define package(`"$name`")"
        }

        $expectedUrl = "https://github.com/blook-project/$name/releases/download/v`$(version)/$name-`$(version)-windows-x64.zip"
        if ($manifest -notmatch [regex]::Escape('releases/download/v$(version)')) {
            Fail "${name}: add_urls must use the version template 'releases/download/v`$(version)'"
        }
        if ($manifest -notmatch [regex]::Escape("github.com/blook-project/$name/releases/download/")) {
            Fail "${name}: add_urls must point at https://github.com/blook-project/$name/releases/download/..."
        }
        if ($manifest -notmatch [regex]::Escape('add_versionfiles("versions.txt")')) {
            Fail "${name}: manifest must call add_versionfiles(\"versions.txt\")"
        }
        if ($manifest -notmatch 'on_install\s*\(\s*"windows"') {
            Fail "${name}: manifest must define on_install(`"windows`", ...)"
        }

        # versions.txt: "<semver> <sha256>" lines, '#' comments allowed.
        $seenVersions = @{}
        $prevVersion = $null
        $lineNo = 0
        $versionEntries = @()
        foreach ($line in (Get-Content -LiteralPath $versionsPath)) {
            $lineNo++
            $trimmed = $line.Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
            if ($trimmed -notmatch '^(\S+)\s+([0-9a-fA-F]{64})$') {
                Fail "$name versions.txt:$lineNo : expected '<version> <sha256>' (64 hex chars), got '$trimmed'"
                continue
            }
            $ver = $Matches[1]
            $sha = $Matches[2].ToLowerInvariant()
            if ($ver -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$') {
                Fail "$name versions.txt:$lineNo : version '$ver' is not semver-ish (X.Y.Z[-pre][+build])"
            }
            if ($seenVersions.ContainsKey($ver)) {
                Fail "$name versions.txt:$lineNo : duplicate version '$ver'"
            }
            $seenVersions[$ver] = $sha
            $versionEntries += [pscustomobject]@{ Version = $ver; Sha = $sha }
            if ($prevVersion -and ([string]::CompareOrdinal($prevVersion, $ver) -gt 0)) {
                Warn "$name versions.txt: versions should be sorted ascending ('$prevVersion' before '$ver')"
            }
            $prevVersion = $ver
            $versionsChecked++
        }

        if ($versionEntries.Count -eq 0) {
            Write-Host "   $name : no published versions yet (manifest structure OK)"
        } else {
            Write-Host "   $name : $($versionEntries.Count) version(s)"
        }

        # Optional: parse with xmake itself and cross-check what it sees.
        if ($WithXmake) {
            Push-Location $xmakeTmp
            try {
                $luaScript = Join-Path $PSScriptRoot 'manifest-check.lua'
                $out = & $Xmake l $luaScript $dir $name 2>&1
                $code = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            $outText = ($out | Out-String)
            if ($code -ne 0 -or $outText -notmatch 'PARSE_OK') {
                Fail "${name}: xmake failed to parse manifest:`n$outText"
            } else {
                $luaUrls = @()
                $luaVersions = @{}
                foreach ($line in ($out | ForEach-Object { "$_" })) {
                    if ($line -match '^URL (.+)$') { $luaUrls += $Matches[1].Trim() }
                    if ($line -match '^VERSION (\S+) (\S+)$') { $luaVersions[$Matches[1]] = $Matches[2].ToLowerInvariant() }
                }
                # NOTE: xmake expands $(version) while loading a manifest (it is empty at parse
                # time), so the URL template is enforced against the manifest source above; here we
                # only require that xmake did see an add_urls() entry.
                if ($luaUrls.Count -eq 0) {
                    Fail "${name}: xmake sees no add_urls() in the manifest"
                }
                foreach ($entry in $versionEntries) {
                    if (-not $luaVersions.ContainsKey($entry.Version)) {
                        Fail "${name}: xmake does not see version $($entry.Version) from versions.txt"
                    } elseif ($luaVersions[$entry.Version] -ne $entry.Sha) {
                        Fail "${name}: sha256 mismatch for $($entry.Version): versions.txt=$($entry.Sha) xmake=$($luaVersions[$entry.Version])"
                    }
                }
            }
        }

        # Optional: verify release assets exist and the sibling .sha256 matches.
        if ($CheckAssets) {
            foreach ($entry in $versionEntries) {
                $zipUrl = $expectedUrl.Replace('$(version)', $entry.Version)
                $urlsChecked++
                try {
                    $resp = Invoke-WebRequest -Uri $zipUrl -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 60
                    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 400) {
                        Fail "$name $($entry.Version): asset HEAD returned HTTP $($resp.StatusCode) ($zipUrl)"
                    }
                } catch {
                    Fail "$name $($entry.Version): asset is not reachable ($zipUrl): $($_.Exception.Message)"
                    continue
                }
                try {
                    $shaResp = Invoke-WebRequest -Uri "$zipUrl.sha256" -UseBasicParsing -TimeoutSec 60
                    $text = [string]$shaResp.Content
                    $m = [regex]::Match($text, '([0-9a-fA-F]{64})')
                    if (-not $m.Success) {
                        Warn "$name $($entry.Version): sibling .sha256 asset has no 64-hex digest"
                    } elseif ($m.Groups[1].Value.ToLowerInvariant() -ne $entry.Sha) {
                        Fail "$name $($entry.Version): release .sha256 ($($m.Groups[1].Value)) != versions.txt ($($entry.Sha))"
                    }
                } catch {
                    Warn "$name $($entry.Version): sibling .sha256 asset missing or unreachable"
                }
            }
        }
    }
} finally {
    if ($xmakeTmp -and (Test-Path -LiteralPath $xmakeTmp)) {
        Remove-Item -LiteralPath $xmakeTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "== checked $checked package(s), $versionsChecked published version(s)"
foreach ($w in $warnings) { Write-Warning $w }
if ($errors.Count -gt 0) {
    Write-Host "== FAILED with $($errors.Count) error(s):"
    foreach ($e in $errors) { Write-Host "   ERROR: $e" }
    exit 1
}
Write-Host '== OK: registry manifests are valid'
exit 0

