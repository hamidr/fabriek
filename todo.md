# To do

Host is a NixOS PC as of 2026-09-16; the machine proofs run here. The
example is served to the machine over git:// from a bare mirror under the
proof directory (`git daemon --base-path=/tmp/fabriek-proof/git`); the
checkout's origin is `git://10.0.2.2/fabriek-example.git`.

- ADR-057's 9p timing and the macOS half of the plan: not measurable here.
  Peak memory during prepare was not captured either.
- ADR-046, re-decided 2026-09-16: fetch on the host at `up` into the lower
  store, lay out at render. Implement (roadmap 6.5).
- ADR-059, proposed 2026-09-16: cut a role's branch from the forge's main
  and reset it once merged. Implement; specialist.sh's guidance scenario
  is the machine proof.
- ADR-052 step 1, the read-only workspace of submodules: its two machine
  measurements passed 2026-09-16, so it can start. ADR-056, the lessons
  service, proposed and untouched.
- `tests/manual/host-autostart.sh` (roadmap 6.8): wants `services.fabriek`
  in this host's NixOS configuration, a rebuild and a reboot, and no
  personal config. The operator's change.
- The gated Thens of specialist.sh and isolation.sh: a model in the loop
  (`FABRIEK_PROOF_MODEL=1`), `enter --print-argv` against seam.bats, and a
  token ceiling under 5000 for the 429.
- nixcage: `nixcage-container exec` keeps an argument's first line only
  (seen 2026-09-16 from a hand session). Upstream, per ADR-018.
- Compose one specialist profile per replicated base and link the rest,
  instead of N identical builds (ADR-053 consequence); under ADR-057 that is
  N `nix build` calls at render, the same store path each time. Evaluation
  cost only; low priority.
