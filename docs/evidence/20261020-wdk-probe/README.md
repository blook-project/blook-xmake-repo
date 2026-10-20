# Evidence: WDK availability on GitHub-hosted `windows-latest` (2026-10-20)

Purpose: de-risk kernel-driver CI for `blook-kchannel`, `blook-kdu`, `blook-drv`, `blook-drv-lite`
before those repos wired their CI. Executed in scratch repo `blook-project/ci-probe`
(run `39478848311`, workflow preserved in [`../../ci-probe.yml`](../../ci-probe.yml); the scratch repo
is deleted after the probe so its job links expire — this file is the durable evidence).

## Setup

- `runs-on: windows-latest`, three jobs run in parallel:
  1. `WDK/SDK inventory` — facts only.
  2. `WDK via NuGet content (fast, no admin)` — recipe A: download `Microsoft.Windows.WDK.x64`
     NuGet 10.0.26100.6584, `tar.exe -xf`, build `probe/` (minimal WDM driver) with
     `xmake f -c -y -m release --wdk=<extract>/c && xmake -y`.
  3. `WDK via official wdksetup.exe (fallback, admin)` — recipe B: `wdksetup.exe /quiet /norestart /features +`,
     then the same build against `C:\Program Files (x86)\Windows Kits\10`.
- Minimal driver project: `probe/xmake.lua` with `add_rules("wdk.driver", "wdk.env.wdm")`,
  `probe/src/driver.cpp` exporting `DriverEntry`, `probe/probedrv.inf`.

## Results (all three jobs green)

See [inventory.txt](inventory.txt) for the raw filtered log lines.

| Fact | Value |
|---|---|
| Image | `win25-vs2026`, ImageVersion `20261018.275.1` (another job of the same run landed on `20261007.264.1`) |
| OS | Windows Server 2025 Datacenter 10.0.26100 |
| Hardware | 4 vCPU, 16 GB RAM |
| VS | VS 2026, catalog version `18.11.0`, auto-detected by xmake |
| Windows SDK | `C:\Program Files (x86)\Windows Kits\10\{Include,Lib}\10.0.26100.0` present |
| **WDK** | **not installed**: `km lib [10.0.26100.0] = False`, `WDKContentRoot=[]`, `preinstalled km libs: 0` |

Recipe A (NuGet WDK content):

```
download_s=6.7 size_mb=106            # NuGet flat-container download
extract_s=1.6                         # tar.exe -xf
WDK_ROOT=D:\a\_temp\wdk\c exists=True # Include/10.0.26100.0/km/ntddk.h present
km lib x64=82 files
kmdf lib dirs=x64
bin dir=True                          # stampinf/drvcat/wmimofck/Inf2Cat(x86) included
build_s=17                            # xmake configure + compile + link
PRODUCED: probedrv.sys size=5120
```

Recipe B (official installer):

```
installer_exit=0 install_s=260.6      # ~4.3 min in the hosted runner
post-install km dirs: C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0
Vsix: ...\Kits\10\Vsix\VS2022\10.0.26100.0\amd64\WDK.vsix
build_s=17.6
PRODUCED: probedrv.sys size=4608
```

Conclusion: kernel repos must install a WDK in CI; recipe A is the default (fast, no admin,
no reboot), recipe B is the fallback (full toolset/Vsix). See
[`docs/CI-WDK.md`](../../CI-WDK.md) for copy-paste workflow snippets.
