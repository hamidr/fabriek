# To do

- Push: main is ten commits ahead of origin/main (ADR-057, 2026-09-16).
- The linux builder on this host has a corrupted store: `nix-store --verify`
  on it reports paths disappeared with valid referrers, `nix-2.34.8` among
  them, and `pi-lsp` cannot build there. Recreate the builder VM (stop the
  nix-darwin `linux-builder` service, remove its disk under
  `/var/lib/darwin-builder`, start it); its cache is all that goes.
- ADR-057's measurement plan on a Linux host (roadmap 6.9): the runtime
  line takes effect, a second `up` copies nothing, nixcage's closure query
  answers for a host path through `local-overlay-store` over the shared
  db, 9p timed against virtiofs. The overlay store is the one claim that
  can sink the design; the fallback (host as substituter) is named in
  point 1a.
- ADR-046, the dependency cache warmed at the machine build: there is no
  machine build to warm at under ADR-057. Re-decide: fetched by the
  evaluator at render, or warmed on the host and shipped as a volume.
- ADR-036, ADR-037, ADR-038 are accepted and, by PRD-006, built; audit
  each against its code as ADR-045, 047 and 048 were and record the
  status.
- ADR-052 step 1, the read-only workspace of submodules, after its two
  machine measurements (safe.directory fetch as root, --reference across
  datasets). ADR-056, the lessons service, proposed and untouched.
- The manual proofs that need a machine (roadmap 6.1 to 6.4, 6.8):
  specialist.sh, host-autostart.sh, isolation.sh with the daemon's two
  probes, nixcage ADR-014's session start over ~1000 binds.
- The clone never fetches main after the first up: a role's branch is cut
  from the main the machine first cloned, so docs/factory-guidance.md
  committed later never reaches a brief (found by tests/manual/specialist.sh,
  ADR-054). Which main a role starts from, and when it moves, wants a record
  of its own (ADR-032 is where the clone was decided). Under ADR-057 render
  fetches the pin on every up, which covers the pinned commit and not main.
- Compose one specialist profile per replicated base and link the rest,
  instead of N identical builds (ADR-053 consequence); under ADR-057 that is
  N `nix build` calls at render, the same store path each time.
