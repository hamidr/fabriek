# To do

- The clone never fetches main after the first up: a role's branch is cut
  from the main the machine first cloned, so docs/factory-guidance.md
  committed later never reaches a brief (found by tests/manual/specialist.sh,
  ADR-054). Which main a role starts from, and when it moves, wants a record
  of its own (ADR-032 is where the clone was decided).
- ADR-052 step 1, the read-only workspace of submodules, after its two
  machine measurements (safe.directory fetch as root, --reference across
  datasets).
- Compose one specialist profile per replicated base and link the rest,
  instead of N identical builds (ADR-053 consequence).
- Push: main is 26 commits ahead of origin/main.
