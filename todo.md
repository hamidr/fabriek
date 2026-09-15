# To do

- Push: main is 33 commits ahead of origin/main.
- Test codegraph on a real project (ADR-049, `tests/manual/specialist.sh`).
- Test the manager's inspection of a task on a real factory (ADR-051).
- Prove on a machine what landed without one: the guidance at the front of
  a role's prompt (ADR-054), a replicated role's cages (ADR-053), the
  concurrency refusal on a live board (ADR-055).
- Add those three scenarios to `tests/manual/specialist.sh` before the
  next machine run.
- ADR-052 step 1, the read-only workspace of submodules, after its two
  machine measurements (safe.directory fetch as root, --reference across
  datasets).
- Compose one specialist profile per replicated base and link the rest,
  instead of N identical builds (ADR-053 consequence).
- Worked examples of the manager's levers in `examples/factory-project`:
  a `docs/factory-guidance.md` and a `decider.policy` file.
