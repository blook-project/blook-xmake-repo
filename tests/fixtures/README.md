# Registry self-test fixtures

`tests/fixtures/` proves the registry mechanics end-to-end on every push, without any product
release involved:

- `assets/blook-registry-selftest-0.1.0.zip` — tiny fixture artifact (one header + one text file).
- `selftest-repo/packages/b/blook-registry-selftest/` — a throwaway registry (git repo created in CI
  from this directory). Its manifest downloads the fixture zip from a **real GitHub Release asset**
  of this repository (tag `selftest-v0.1.0`), so URL resolution, sha256 verification and `on_install`
  are all exercised over HTTPS.
- `consumer/` — an xmake project that `add_repositories` + `add_requires` the package and includes
  its header; the CI job builds and runs it.

Reproducing locally (Windows, xmake + git on PATH):

```powershell
$repo = "$env:TEMP\blook-selftest-repo"
Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $repo | Out-Null
Copy-Item tests/fixtures/selftest-repo/* $repo -Recurse
git init -q -b main $repo; git -C $repo add -A
git -C $repo -c user.name=ci -c user.email=ci@example.invalid commit -qm selftest
$env:SELFTEST_REPO_URL = 'file:///' + ($repo -replace '\\', '/')
Push-Location tests/fixtures/consumer
xmake f -c -y -m release; xmake -y; xmake run consumer
Pop-Location
```

Re-creating the fixture release (only if the tag/asset is ever lost — the `0.1.0` hash in
`selftest-repo/.../versions.txt` must match the published zip):

```powershell
$ver = '0.1.0'
$zip = "tests/fixtures/assets/blook-registry-selftest-$ver.zip"
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$sha  $(Split-Path $zip -Leaf)" | Set-Content "$zip.sha256"
gh release create selftest-v$ver -R blook-project/blook-xmake-repo `
  --title "registry self-test fixture $ver" `
  --notes "Fixture artifact for .github/workflows/validate.yml (not a product release)." `
  $zip "$zip.sha256"
```

Keep the zip deterministic enough that its hash does not change; if it must change, publish a new
`0.2.0` fixture and update both `versions.txt` and the manifest asset name instead of reusing `0.1.0`.
