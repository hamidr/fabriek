# To do

Host is a NixOS PC as of 2026-09-16; every machine proof below can run here.

- ADR-057's measurement plan (roadmap 6.9): the runtime line takes effect,
  a second `up` copies nothing, nixcage's closure query answers for a host
  path through `local-overlay-store` over the shared db, 9p timed against
  virtiofs. The overlay store is the one claim that can sink the design;
  the fallback (host as substituter) is named in point 1a. First.
- The manual proofs that need a machine (roadmap 6.1 to 6.4, 6.8):
  specialist.sh, host-autostart.sh, isolation.sh with the daemon's two
  probes, nixcage ADR-014's session start over ~1000 binds. Run with the
  item above.
- ADR-046, the dependency cache warmed at the machine build: there is no
  machine build to warm at under ADR-057. Re-decide: fetched by the
  evaluator at render, or warmed on the host and shipped as a volume.
  Fold in the profile question below.
- ADR-038 has no status line against its code; audit it as ADR-045, 047
  and 048 were. ADR-036 and ADR-037 carry a 2026-09-13 status from a
  machine that predates ADR-057; re-check them once the machine runs here.
- ADR-052 step 1, the read-only workspace of submodules, after its two
  machine measurements (safe.directory fetch as root, --reference across
  datasets). ADR-056, the lessons service, proposed and untouched.
- The clone never fetches main after the first up: a role's branch is cut
  from the main the machine first cloned, so docs/factory-guidance.md
  committed later never reaches a brief (found by tests/manual/specialist.sh,
  ADR-054). Which main a role starts from, and when it moves, wants a record
  of its own (ADR-032 is where the clone was decided). Under ADR-057 render
  fetches the pin on every up, which covers the pinned commit and not main.
- Compose one specialist profile per replicated base and link the rest,
  instead of N identical builds (ADR-053 consequence); under ADR-057 that is
  N `nix build` calls at render, the same store path each time. Evaluation
  cost only; low priority.
