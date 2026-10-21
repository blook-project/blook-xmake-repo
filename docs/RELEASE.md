# Release → registry flow

Every repo in `blook-project` follows the same release contract. A release is "done" only when the
registry can install the new version via `add_requires`.

```
 repo (e.g. blook-kchannel)                                    registry (blook-xmake-repo)
 ───────────────────────────                                   ────────────────────────────
 1. bump version.txt + CHANGELOG
 2. git tag vX.Y.Z && git push --tags
 3. GitHub Actions "release" workflow:
      build + unit tests
      zip include/ lib/ bin/ ...            ── asset ──▶  vX.Y.Z release asset
      <pkg>-X.Y.Z-windows-x64.zip
      <pkg>-X.Y.Z-windows-x64.zip.sha256
                                                              4. scripts/publish-registry.ps1
                                                                 reads release via gh, adds
                                                                 "<X.Y.Z> <sha256>" to
                                                                 packages/<l>/<pkg>/versions.txt,
                                                                 commits + pushes
                                                                       │
                                                      5. consumers pin the version ──▶ xmake install
```

## 1. Release asset contract (owned by each repo's `release.yml`)

On tag `vX.Y.Z` the repo publishes a GitHub Release with:

| Asset | Required | Notes |
|---|---|---|
| `<package>-<version>-windows-x64.zip` | yes | e.g. `blook-kchannel-1.0.0-windows-x64.zip` |
| `<package>-<version>-windows-x64.zip.sha256` | yes (or registry script hashes the zip) | lowercase 64-hex digest; may be `<digest>  <filename>` |
| source tarballs | GitHub default | fine |

Zip layout (only the directories the repo actually has):

```
include/...            # public user-mode + kernel headers
lib/x64/*.lib          # optional static/import libs
bin/x64/*.exe|*.dll|*.sys   # optional tools/runtime
scripts/...            # optional helper scripts
docs/...               # optional
README.md LICENSE CHANGELOG.md
```

Keep archives small: no `build/`, no `*.pdb` (or `pdb` optional), no VM images, no private keys.
CI *test*-signs artifacts only if needed; real SPC signing happens locally per repo conventions.

Reference `release.yml` skeleton (copy into a repo, adjust target/package names):

```yaml
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: xmake-io/github-action-setup-xmake@v1
      - name: Install WDK (kernel repos; see docs/CI-WDK.md)
        shell: pwsh
        run: |
          $ver = '10.0.26100.6584'
          $dst = "$env:RUNNER_TEMP\wdk"
          New-Item -ItemType Directory -Force $dst | Out-Null
          Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$ver/microsoft.windows.wdk.x64.$ver.nupkg" -OutFile "$dst\wdk.nupkg"
          tar.exe -xf "$dst\wdk.nupkg" -C $dst
          "WDK_ROOT=$dst\c" >> $env:GITHUB_ENV
      - name: Build + unit tests
        shell: pwsh
        run: |
          xmake f -y -m release --wdk="$env:WDK_ROOT"
          xmake -y
          # xmake run <unit test targets> ...
      - name: Package
        shell: pwsh
        run: |
          $ver = (Get-Content version.txt -Raw).Trim()
          $pkg = 'blook-<name>'
          $stage = "stage/$pkg-$ver-windows-x64"
          New-Item -ItemType Directory -Force $stage | Out-Null
          foreach ($d in @('include','lib','bin','scripts','docs')) {
            if (Test-Path $d) { Copy-Item $d $stage -Recurse }
          }
          Copy-Item README.md,CHANGELOG.md,LICENSE $stage -ErrorAction SilentlyContinue
          Compress-Archive -Path "$stage/*" -DestinationPath "$pkg-$ver-windows-x64.zip" -Force
          $sha = (Get-FileHash "$pkg-$ver-windows-x64.zip" -Algorithm SHA256).Hash.ToLower()
          "$sha  $pkg-$ver-windows-x64.zip" | Set-Content "$pkg-$ver-windows-x64.zip.sha256"
      - name: Create GitHub Release
        shell: pwsh
        run: |
          $ver = (Get-Content version.txt -Raw).Trim()
          $pkg = 'blook-<name>'
          gh release create "v$ver" --title "v$ver" --notes-file CHANGELOG.md `
            "$pkg-$ver-windows-x64.zip" "$pkg-$ver-windows-x64.zip.sha256"
```

## 2. Publish into the registry

Use `scripts/publish-registry.ps1` from this repo (`blook-xmake-repo/scripts/`). Owners can copy it
into their repo, or call it from the registry clone. It only needs the developer's `gh` auth — no org
secret.

```powershell
# 1) dry run first (no push, no local changes kept)
pwsh ./scripts/publish-registry.ps1 -Package blook-kchannel -Version 1.0.0 -DryRun

# 2) publish
pwsh ./scripts/publish-registry.ps1 -Package blook-kchannel -Version 1.0.0
```

What it does:

1. `gh release view v<version> -R blook-project/<package>` — fails if the tag/release is missing or a draft.
2. Picks the `.zip` asset (canonical name preferred), rejects empty assets.
3. Resolves sha256: from the `.sha256` asset if present, else downloads the zip and hashes it.
   `-Sha256 <hex>` overrides (useful in CI).
4. Clones `blook-project/blook-xmake-repo` (or uses `-RegistryDir <clone>`), verifies the manifest's
   `add_urls` already points at `https://github.com/blook-project/<package>/releases/download/...`.
5. Rewrites `packages/<l>/<package>/versions.txt` (`<version> <sha256>`, sorted ascending, LF endings).
6. Verifies the package actually installs (`xmake f` in a throwaway consumer project, `-NoVerify` to skip).
7. Commits `registry: publish <package> <version>` and pushes to `main`.

First publish of a brand-new package (`packages/<l>/<pkg>/` does not exist yet):

```powershell
# each repo ships its package definition in xmake-package/xmake.lua
pwsh ./scripts/publish-registry.ps1 -Package blook-drv -Version 1.0.0 `
     -ManifestFile D:\blook-kernel-project\blook-drv\xmake-package\xmake.lua
```

The manifest must use the canonical URL template, e.g.:

```lua
package("blook-kchannel")
    add_urls("https://github.com/blook-project/blook-kchannel/releases/download/v$(version)/blook-kchannel-$(version)-windows-x64.zip")
    add_versionfiles("versions.txt")
    on_install("windows", function (package) ... end)
```

Flags: `-DryRun`, `-NoPush`, `-NoVerify`, `-AssetName <name>`, `-Repo <owner/repo>` (only for
renamed repos / testing), `-RegistryDir <clone>`, `-Xmake <path>`.

## 3. Verify a consumer installs it

```lua
-- consumer/xmake.lua
add_repositories("blook https://github.com/blook-project/blook-xmake-repo.git")
add_requires("blook-kchannel 1.0.0")
target("app")
    set_kind("binary")
    add_files("main.cpp")
    add_packages("blook-kchannel")
```

```powershell
xmake f -c -y -m release && xmake -y            # downloads + verifies sha256 + installs
xmake require --force -v blook-kchannel         # reinstall/refresh the cached package
```

Any hash mismatch, 404 asset or missing version aborts the configure step — that is the gate that
makes the registry trustworthy. `scripts/validate-registry.ps1 -CheckAssets` re-checks all published
assets (HEAD + `.sha256` comparison) in CI on every push.

## 4. CI-side automation (optional, no org secret required by default)

The default flow is developer-driven after the tag (step 2). If a repo wants to update the registry
automatically from `release.yml`, configure a **`REPO_TOKEN`** secret in that repo (a classic PAT with
`repo` scope, owned by a blook-project admin) and add a final job:

```yaml
  publish-registry:
    needs: release
    runs-on: windows-latest
    if: startsWith(github.ref, 'refs/tags/v')
    steps:
      - name: Publish to blook-xmake-repo
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.REPO_TOKEN }}
        run: |
          $ver = $env:GITHUB_REF_NAME -replace '^v',''
          gh repo clone blook-project/blook-xmake-repo registry -- --quiet --depth 1
          gh release view "v$ver" -R "blook-project/${{ github.event.repository.name }}" --json assets
          pwsh registry/scripts/publish-registry.ps1 -Package blook-kchannel -Version $ver -NoVerify
```

Notes:

- `REPO_TOKEN` is **optional**; document it, never commit it. Without it, the release job still
  produces the assets and a human/agent runs the publish script locally.
- The script's commit is authored with the project identity; the push uses the token.
- Keep `-NoVerify` in CI (the runner can't reach a private registry after the project flips private
  without the same token; the local run covers verification).

## 4b. Troubleshooting: local xmake downloads behind a system proxy

xmake's bundled curl does **not** read Windows WinINET/system proxy settings (only HTTPS_PROXY/
HTTP_PROXY environment variables). On a dev host with a local proxy (e.g. 127.0.0.1:7890), a
registry publish verification or a plain xmake f may fail with:

`
curl: (28) Failed to connect to github.com port 443 ... Could not connect to server
`

Fix: export the proxy for xmake (and any child process):

`powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
pwsh ./scripts/publish-registry.ps1 -Package blook-vmware-environment -Version 0.1.0
`

GitHub-hosted CI runners have direct network access, so workflows do not need this. The publish
script's own gh/Invoke-WebRequest calls use WinINET and already work behind the proxy; only the
embedded xmake download step needs the env vars.
## 5. Rules

- **Version is immutable.** Never re-upload different bytes under an existing `vX.Y.Z` tag; publish a
  new version instead. The script refuses to publish an empty asset and warns when replacing a hash.
- `version.txt` in each repo is the single source of truth; the tag must equal `v` + `version.txt`.
- Pre-releases (`vX.Y.Z-rc.1`) work the same way; `versions.txt` keeps them in semver order.
- Once the project is flipped private, `add_repositories` over HTTPS needs credentials:
  `git config --global credential.helper manager` + a PAT, or a local registry clone with
  `add_repositories("blook <local path>")` for internal builds.
- Registry commits: `registry: publish <package> <version>` (scope = registry).

## 6. Validation record (end-to-end proof)

The flow above was validated end-to-end before any product release existed, using a scratch release
in `blook-project/ci-probe` (a fixture package `blook-fixture` 9.9.9 pointing at a real GitHub
Release asset) plus the registry self-test in CI. Full details:
[`evidence/20261020-registry-validation/`](evidence/20261020-registry-validation/README.md).

1. `gh release create v9.9.9 -R blook-project/ci-probe blook-fixture-9.9.9-windows-x64.zip blook-fixture-9.9.9-windows-x64.zip.sha256`
2. `pwsh scripts/publish-registry.ps1 -Package blook-fixture -Version 9.9.9 -Repo blook-project/ci-probe -ManifestFile <fixture xmake-package/xmake.lua> -NoPush`
   → cloned the real registry, created `packages/b/blook-fixture/versions.txt` with the right sha256,
   committed `registry: publish blook-fixture 9.9.9`, and **installed the package from the GitHub
   Release URL in the verification project** (green).
3. `.github/workflows/validate.yml` run `39480017124` is green: manifest lint/parse for all five
   package manifests plus an e2e install of `blook-registry-selftest 0.1.0` from the real
   `selftest-v0.1.0` release asset, including building a consumer against it.
4. When an owner publishes `blook-kchannel v1.0.0`, the same command with the real repo replaces the
   fixture and the registry then serves the real package (`versions.txt` line only, no script change).

The registry self-test in CI (`tests/fixtures/`, `.github/workflows/validate.yml`) keeps proving the
asset-URL + sha256 + on_install path on every push, without any product release involved.

