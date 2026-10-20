# blook-project xmake package registry

xrepo-compatible package registry for the [blook-project](https://github.com/blook-project) kernel-security repositories.

Consumers (`blook-kdu`, `blook-drv`, `blook-drv-lite`, sample projects, CI) can pull released artifacts
from this registry instead of vendoring headers or using git submodules:

```lua
add_repositories("blook https://github.com/blook-project/blook-xmake-repo.git")
add_requires("blook-kchannel 1.0.0")

target("myapp")
    set_kind("binary")
    add_packages("blook-kchannel")
```

`add_repositories` must appear in the root `xmake.lua` (before `add_requires`).

## Packages

| Package | Repo | Description |
|---|---|---|
| `blook-kchannel` | [blook-kchannel](https://github.com/blook-project/blook-kchannel) | Kernel↔user shared-memory IPC transport (ChaCha20 + HMAC-SHA256, mapped-driver capable) |
| `blook-kdu` | [blook-kdu](https://github.com/blook-project/blook-kdu) | Modular driver-mapping / kernel-exploitation toolkit + user-mode SDK |
| `blook-drv` | [blook-drv](https://github.com/blook-project/blook-drv) | Hardened hypervisor driver + user-mode EPT / hardware-breakpoint hook SDK |
| `blook-drv-lite` | [blook-drv-lite](https://github.com/blook-project/blook-drv-lite) | Lite manual-map kernel driver + SDK (memory r/w, DSE, object handles, InfinityHook) |
| `blook-vmware-environment` | [blook-vmware-environment](https://github.com/blook-project/blook-vmware-environment) | `bvmenv` CLI: VMware test-environment lifecycle (fork / exec / push / state / e2e / reset) |

Published versions and their sha256 live in each package's `versions.txt`; versions are added by
`scripts/publish-registry.ps1` after a repo publishes a GitHub Release (see [docs/RELEASE.md](docs/RELEASE.md)).

## Layout

```
packages/<first-letter>/<package>/xmake.lua     # package definition (xrepo format)
packages/<first-letter>/<package>/versions.txt  # "<version> <sha256>" per line
docs/CI-WDK.md                                  # proven WDK-on-GitHub-runners recipe
docs/RELEASE.md                                 # tag → release → registry flow
scripts/publish-registry.ps1                    # local publish helper (uses gh auth)
scripts/validate-registry.ps1                   # manifest/URL/sha256 validator (run in CI)
tests/fixtures/                                 # registry self-test (consumer project + fixture package)
```

## How artifacts are addressed

Every package points at the GitHub Release asset of its repo via a **version template**:

```
https://github.com/blook-project/<repo>/releases/download/v$(version)/<repo>-$(version)-windows-x64.zip
```

`$(version)` is substituted by xmake from the resolved version. The matching sha256 is mandatory:
xmake refuses to install a version that has no hash. Hash verification failures are hard errors.

Release asset contract (produced by each repo's `release.yml`):

```
<package>-<version>-windows-x64.zip
  include/...            # public user-mode / kernel headers
  lib/x64/*.lib          # optional static libs
  bin/x64/*              # optional tools / binaries
  scripts/...            # optional helper scripts
  README.md LICENSE CHANGELOG.md
<package>-<version>-windows-x64.zip.sha256   # lowercase hex digest
```

`on_install` in the manifests copies whichever of `include/ lib/ bin/ share/ scripts/` exist into the
package install dir, so a repo only has to ship the directories it actually has.

## Consuming the packages

```lua
-- root xmake.lua
add_repositories("blook https://github.com/blook-project/blook-xmake-repo.git")
add_requires("blook-kchannel 1.0.0")

target("loader")
    set_kind("binary")
    add_packages("blook-kchannel")
```

`add_packages` adds the package include dirs (`include/`), link dirs (`lib/`, `lib/x64/`) and bindirs
(`bin/`, `bin/x64/`) when they exist. Library names are package-specific, link them explicitly, e.g.
`add_links("blook_kchannel")` (ask the owning repo, or inspect the zip). Kernel targets built against
the package need the WDK, see [docs/CI-WDK.md](docs/CI-WDK.md).

Local development does not have to go through the registry: each repo accepts a source-tree override,
e.g. `xmake f --kchannel_dir=D:\blook-kernel-project\blook-kchannel`.

### Pinning / overriding

```lua
add_requires("blook-kchannel 1.0.0")                 -- exact version
add_requires("blook-kchannel 1.0.0", {verify = true}) -- explicit (sha256 is always verified)
```

xmake caches installed packages per user (`~/.xmake/packages`); use `xmake require --force` after
republishing a version, and never republish different bits under an existing version tag.

## Validating the registry

```powershell
pwsh ./scripts/validate-registry.ps1                 # structure + versions.txt + sha256 checks
pwsh ./scripts/validate-registry.ps1 -WithXmake      # + parse every manifest with xmake
pwsh ./scripts/validate-registry.ps1 -CheckAssets    # + HEAD the release asset URLs
```

CI runs `.github/workflows/validate.yml` on every push: manifest/sha256 lint plus an end-to-end
install of the self-test package from a **real GitHub Release asset** (`tests/fixtures/`), which proves
the URL template, hash verification and `on_install` rules work without touching product packages.

## Notes

- Public during development; the project may be switched to private at the end. `add_repositories`
  with a private repo needs a token (`xmake g --insecure-ssl` / `gh auth token` based git credentials).
- Never commit private keys, PATs or release binaries here; only manifests, versions and docs.
- License: MIT (see [LICENSE](LICENSE)).
