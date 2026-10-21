# CI runs real kernel code on windows-latest

Evidence for the "kernel-load in CI" capability (Lead probe, 2026-10-21).

- **Result:** hosted `windows-latest` can `sc create/start` a **real SPC SHA-1-signed** WDM driver and reach
  `STATE 4 RUNNING` (kernel code executes in CI, no test-signing reboot).
- **Recipe:** `spcsign sign --sha1 --cert XINDA --tsa-time 2013-01-01T00:00:00Z --chain verisign-cscs-2010.cer
  --chain verisign-g5-mcvr.cer`, then on the runner import the TSA root (`certutil -addstore -f root
  signer/tsa/tsa-root.cer`), the two Verisign CA certs, and the XINDA leaf into `TrustedPublisher`; verify
  with `signtool verify /kp`. Before the TSA root is trusted, `/kp` fails `0x80096005`.
- **SHA-256 is broken** in the signer path (`TRUST_E_BAD_DIGEST` 0x80096010) — use `--sha1`.
- **Proven implementations:** `blook-drv-lite` job `kernel-load-smoke` (run 39593960380, `19a37b8`) green with
  a kernel read (`4d 5a`) after load; `blook-kchannel` job `kernel-smoke (real load, SPC-signed)` reached
  `STATE 4 RUNNING` on the runner (only its host-safety client guard prevented the follow-up).
- **Image facts:** windows-2025-vs2026, Windows Server 2025 10.0.26100, `testsigning Yes`, SecureBoot off,
  runner runs as admin.
- **Still VM-only:** `blook-drv` hypervisor (nested VT-x / EPT) — cannot be exercised on hosted runners.
- Caution: a probe driver with a device+IOCTL hung the runner at `sc start`; guard `sc start` with a process
  timeout and use a minimal DriverEntry-only smoke driver first.
