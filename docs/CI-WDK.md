# WDK on GitHub-hosted runners — empirical findings + copy-paste recipe

Status: **verified green** on `windows-latest` (scratch repo run `39478848311`; durable evidence in
[`evidence/20261020-wdk-probe/`](evidence/20261020-wdk-probe/README.md), workflow in
[`ci-probe.yml`](ci-probe.yml); the scratch repo `blook-project/ci-probe` is deleted after the probe).
Both recipes below were executed end-to-end in that run and produced `probedrv.sys`.
Owners: `ci`. Applies to every repo that builds a kernel driver: `blook-kchannel`, `blook-kdu`, `blook-drv`, `blook-drv-lite`.

## Verdict: the runner ships the Windows SDK, but **not** the WDK

Probe run (scratch repo `blook-project/ci-probe`; the exact workflow is kept here as
[`ci-probe.yml`](ci-probe.yml)):

| Fact | Value |
|---|---|
| Runner image | `windows-2025-vs2026`, ImageVersion `20261007.264.1` (inventory job landed on `20261018.275.1`) |
| OS | Windows Server 2025 Datacenter, 10.0.26100 |
| Runner size | 4 vCPU, 16 GB RAM, ~70 GB free on `C:` |
| Windows SDK | `C:\Program Files (x86)\Windows Kits\10\{Include,Lib}\10.0.26100.0` — **present** |
| WDK km libs | `C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\km` — **MISSING** (`preinstalled km libs: 0`) |
| `WDKContentRoot` | empty |
| Visual Studio | VS 2026 `18.11.0` preinstalled, auto-detected by xmake |

Consequence: `add_rules("wdk.driver")` fails with `fatal error C1083: cannot open include file: 'ntddk.h'`
until a WDK is brought in. Do **not** rely on the image having a WDK.

## Recipe A (recommended): WDK content from NuGet — no admin, no installer, fast

Microsoft publishes the full WDK content as NuGet packages (`Microsoft.Windows.WDK.x64`,
`...ARM64`, `...x86`). They contain `Include\<sdkver>\{km,um,shared,wdf}`, `Lib\<sdkver>\{km,um}\x64`,
`Lib\wdf\...` — exactly the layout xmake's `find_wdk` expects. Extract once per job and pass
`--wdk=<extract>\c`.

Measured on the probe job (`windows-latest`):

| Step | Time |
|---|---|
| `Invoke-WebRequest` 106 MB nupkg | **6.7 s** |
| `tar.exe -xf` extract (~300 MB on disk) | **1.6 s** |
| content sanity checks | < 1 s |
| `xmake f -c -y` + `xmake -y` (configure + compile + link) | **17 s** |
| produced | `probedrv.sys` (5120 bytes), 82 km libs under `Lib\10.0.26100.0\km\x64` |

```yaml
jobs:
  build:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup xmake
        uses: xmake-io/github-action-setup-xmake@v1

      - name: Install WDK (NuGet content, no admin)
        shell: pwsh
        run: |
          # Keep this in sync with the SDK version preinstalled on the runner image.
          $ver = '10.0.26100.6584'
          $dst = "$env:RUNNER_TEMP\wdk"
          New-Item -ItemType Directory -Force $dst | Out-Null
          $url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$ver/microsoft.windows.wdk.x64.$ver.nupkg"
          Invoke-WebRequest -Uri $url -OutFile "$dst\wdk.nupkg" -UseBasicParsing
          & tar.exe -xf "$dst\wdk.nupkg" -C $dst
          # sanity check: kernel headers + libs must be there
          if (-not (Test-Path "$dst\c\Include\10.0.26100.0\km\ntddk.h")) { throw "WDK headers missing" }
          if (-not (Test-Path "$dst\c\Lib\10.0.26100.0\km\x64"))       { throw "WDK km libs missing" }
          "WDK_ROOT=$dst\c" >> $env:GITHUB_ENV

      - name: Configure + build
        shell: pwsh
        run: |
          xmake f -y -m release --wdk="$env:WDK_ROOT"
          xmake -y
```

Notes:

- `$env:WDK_ROOT` is the directory that contains `Include\` and `Lib\` (the `c\` subdir of the
  extracted nupkg). Passing the `Windows Kits\10` directory does **not** help — km libs are absent there.
- Version choice: use the newest `10.0.26100.*` (matches the runner SDK `10.0.26100.0`). For other
  SDK generations pick the matching package version, e.g. `10.0.22621.*`.
- The nupkg is ~105 MB and extracts to ~300 MB. Bundled `bin\10.0.26100.0\x64` has
  `stampinf.exe`, `drvcat.exe`, `wmimofck.exe`, `apivalidator.exe`, `aitstatic.exe`; `Inf2Cat.exe` is
  x86-only in the package. `signtool.exe` / `inf2cat.exe` are also already in the runner's
  `C:\Program Files (x86)\Windows Kits\10\bin\...`. A plain `xmake` compile+link driver build needs
  only headers/libs.
- Caching is optional: `actions/cache` on `$env:RUNNER_TEMP\wdk` (or a fixed path) with key
  `wdk-10.0.26100.6584` saves the download on warm runs.

## Recipe B (fallback): official installer, silent

Needed only if you require the full WDK toolset (Vsix/MSBuild driver integration, `wdksign`,
`inf2cat` wrapper) or if the NuGet route is unavailable. It needs elevation (GitHub-hosted Windows
runners are admin, so `Start-Process -Wait` works) and is much slower.

Measured on the probe job: download + **install 260.6 s (~4.3 min)**, exit code `0`; result
`C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\km` + VSIX
`C:\Program Files (x86)\Windows Kits\10\Vsix\VS2022\10.0.26100.0\{amd64,arm64}\WDK.vsix`;
subsequent xmake build 17.6 s, `probedrv.sys` (4608 bytes).

```yaml
      - name: Install WDK via official wdksetup.exe (silent)
        shell: pwsh
        run: |
          $setup = "$env:RUNNER_TEMP\wdksetup.exe"
          Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2272234' -OutFile $setup -UseBasicParsing
          $p = Start-Process -FilePath $setup -ArgumentList '/quiet','/norestart','/features','+' -Wait -PassThru -NoNewWindow
          "installer exit=$($p.ExitCode)"
          $km = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Lib' -Directory |
                Where-Object { Test-Path "$($_.FullName)\km" }
          if (-not $km) { throw 'WDK installer did not produce km libs' }
          "WDK_VERSION=$($km[-1].Name)" >> $env:GITHUB_ENV

      - name: Configure + build
        shell: pwsh
        run: |
          xmake f -y -m release --wdk="C:\Program Files (x86)\Windows Kits\10"
          xmake -y
```

`fwlink ?linkid=2272234` is the WDK 10.0.26100 web installer. If Microsoft rotates the link, get the
current one from <https://developer.microsoft.com/windows/downloads/windows-ddk/> (the file is
`wdksetup.exe`). Installer exit codes `0` and `3010` (reboot required) are both "installed"; the
reboot is not needed for command-line xmake builds.

## xmake-specific gotchas (these cost real debugging time)

1. **Use the right env rule.** A kernel driver target needs:
   ```lua
   target("mydriver")
       add_rules("wdk.driver", "wdk.env.wdm")   -- plain WDM driver
       -- or: add_rules("wdk.driver", "wdk.env.kmdf")
       add_files("src/*.cpp")
   ```
   `add_rules("wdk.driver")` alone does not add `ntddk.h` include dirs (`wdk.driver` only wires the
   packaging/signing/inf sub-rules; `wdk.env.<type>` provides include/link dirs and defines).
2. **WDK path option is `--wdk=`** (`xmake f --wdk=...`), with optional `--wdk_sdkver=10.0.26100.0`
   and `--wdk_winver=`. An option named `--wdk_dir` is repo-specific sugar: forward it to `--wdk`.
3. `wdk.env` detects the WDK from `--wdk`, then `WDKContentRoot`, then `WindowsSdkDir` from the msvc
   toolchain's vcvars. On the runner `WindowsSdkDir` points at a WDK-less `Windows Kits\10`, so always
   pass `--wdk` explicitly (or set `WDKContentRoot` in the test/install step).
4. The default kernel entrypoint xmake links is `GsDriverEntry` (WDM) / `FxDriverEntry` (KMDF). A plain
   `extern "C" NTSTATUS DriverEntry(...)` works with WDM.
5. `xmake f -c -y` is needed when switching `--wdk` between runs, because xmake caches the detected
   WDK in `.xmake/`.

## Minimal probe project (used to prove the recipe)

`probe/xmake.lua`:

```lua
add_rules("mode.debug", "mode.release")

target("probedrv")
    add_rules("wdk.driver", "wdk.env.wdm")
    add_files("src/*.cpp")
    set_values("wdk.inf", "probedrv.inf")
```

`probe/src/driver.cpp`:

```cpp
#include <ntddk.h>

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath) {
    UNREFERENCED_PARAMETER(RegistryPath);
    DriverObject->DriverUnload = nullptr;
    DbgPrint("[probedrv] loaded WDK CI probe\n");
    return STATUS_SUCCESS;
}
```

Local reproduction (this host, WDK at `Y:\Program Files (x86)\Windows Kits\10`):

```powershell
xmake f -c -y -m release --wdk="Y:\Program Files (x86)\Windows Kits\10"
xmake -y        # build\windows\x64\release\probedrv.sys
```

## Checklist for kernel repos

- [ ] `ci.yml` installs WDK via Recipe A before `xmake f`/`xmake`.
- [ ] `xmake f` passes `--wdk` (or `--wdk_dir` forwarded to it); no hardcoded local `Y:\` path.
- [ ] kernel targets use `wdk.env.wdm` or `wdk.env.kmdf`.
- [ ] CI assert fails loudly if `Lib\<ver>\km` is absent (so a future image change is caught).
- [ ] `release.yml` builds the same way and zips `include/ lib/ bin/` per
      [RELEASE.md](RELEASE.md#release-asset-contract).
