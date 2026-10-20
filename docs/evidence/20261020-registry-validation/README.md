# Evidence: registry validation + publish automation (2026-10-20/21)

## 1. `validate.yml` green on first push

Run `39480017124` — both jobs green:

| Job | Steps |
|---|---|
| `manifests + sha256 lint` | structure + xmake-parse all 5 manifests, then published-asset HEAD check |
| `e2e install from GitHub Release asset` | build throwaway git registry from `tests/fixtures/selftest-repo`, `xmake f` + `xmake -y` + `xmake run consumer` |

The e2e job installs `blook-registry-selftest 0.1.0` from the **real release asset**
`https://github.com/blook-project/blook-xmake-repo/releases/download/selftest-v0.1.0/blook-registry-selftest-0.1.0.zip`
(sha256 `fd87e11c…fcd3` from the fixture `versions.txt`), proving URL resolution, hash verification,
`on_install` and `on_load` package rules end-to-end over HTTPS.

## 2. `scripts/publish-registry.ps1` end-to-end proof

Because no product repo had a release yet, a scratch fixture release was used:
`blook-project/ci-probe` tag `v9.9.9` with
`blook-fixture-9.9.9-windows-x64.zip` (+ `.sha256`) and a manifest at
`ci-probe/xmake-package/xmake.lua` (package `blook-fixture`).

Command (from a clone of this registry; `-NoPush` so the probe package never lands in `main`):

```powershell
pwsh ./scripts/publish-registry.ps1 -Package blook-fixture -Version 9.9.9 `
     -Repo blook-project/ci-probe `
     -ManifestFile ..\..\.qa\ci-probe\xmake-package\xmake.lua -NoPush
```

Output (abridged):

```
==> release: blook-project/ci-probe v9.9.9
==> asset: blook-fixture-9.9.9-windows-x64.zip (0.6 KiB)
==> sha256: downloading blook-fixture-9.9.9-windows-x64.zip.sha256 from the release
==> sha256: 488fb2a288fb34ed587a7af7cb6feec058c056f11ca7191e163e5a227e2b8691
==> registry: cloning blook-project/blook-xmake-repo
==> registry: creating new package from ...\ci-probe\xmake-package\xmake.lua
==> verify: installing the published version from the local registry clone
   verified: blook-fixture 9.9.9 installs from https://github.com/blook-project/ci-probe/releases/download/v$(version)/blook-fixture-$(version)-windows-x64.zip
==> registry: committed d439b02 locally (-NoPush)
```

So: GitHub Release → asset + `.sha256` resolution → registry clone (real HTTPS) → `versions.txt`
update → commit → **consumer install from the GitHub Release URL** all worked. The registry clone used
for verification is a `file://` git clone of the committed state (that is why the script commits before
verifying and rolls the commit back on failure).

## 3. Consumption path sanity check

A throwaway consumer project with
`add_repositories("blook https://github.com/blook-project/blook-xmake-repo.git")` +
`add_requires("blook-kchannel 1.0.0")` cloned the registry over HTTPS (`updating repositories .. ok`)
and failed only with `package(blook-kchannel): no available schemes with urls and versions` — expected,
because no product version is published yet. The first real publish (blook-kchannel v1.0.0) closes
that gap.

Re-run the registry validation locally with `pwsh ./scripts/validate-registry.ps1 -WithXmake -CheckAssets`.
