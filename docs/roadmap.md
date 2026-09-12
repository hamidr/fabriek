# Roadmap

The steps from the design that runs today (`docs/architecture.md`) to the one
`REDESIGN-LOG.md` agreed. Decision numbers refer to that log until phase 0.5
moves them into ADRs; after that the ADR is the reference and this file is
updated to name it.

No docmeta frontmatter on purpose: this is a plan, not a decision, and
`docmeta-tracker` should not index it. PRD-006 (phase 0.5) will carry these
phases as its own, and this file then points at it.

Status is kept here, one line per item, edited when an item's exit holds.
Nothing below is started as of 2026-09-12.

Ordered by dependency. Nothing in a phase starts before the previous phase's
exit holds, except phase 1, which is upstream and runs beside phase 0. Every
item names what exists when it is done; "written" means committed and green.

## Phase 0: gates, on `main`

The parity bar and the models exist before the branch does (decisions 37
and 38, section 4).

- 0.1 `models/routing.qnt`: executor, board, bus, actors that crash, stall
  and lie at reconciliation; `assigning` and `assigned` as distinct rows;
  send and ack as separate steps. Invariants from section 4. Exit:
  `quint run --invariant=allInvariants --max-steps=60` green, and a
  deliberately broken variant (record on ack only) reports the violation.
- 0.2 `models/factory-structure.als` extended: decider and executor as
  subjects, capability provided by role, stage as label, memory issue per
  role, token scope per account. Exit: `alloy6 exec` green.
- 0.3 `models/vm-lifecycle.qnt` amended: rebuild is the normal path, drain is
  per task. Exit: green.
- 0.4 Decision 48 amended to the TUI scope decision 53 implies.
- 0.5 ADRs and a PRD, through `adr-write` and `prd-new`: one ADR per
  reversal in section 3, amendments to the ADRs that stand, PRD-006 carrying
  this roadmap as its phases. `docmeta-tracker docs` regenerated. Exit: this
  file is redundant and says so at its top.
- 0.6 `tests/manual/parity.sh` written as a script that fails: the journey
  of decision 38 as steps with a check each, and `tests/manual/isolation.sh`
  with the two bridge rules and spend attribution. Exit: both run and fail
  for the right reason on today's machine.

## Phase 1: nixcage interface, upstream

Two commits in two repositories and a lock bump each (ADR-018).

- 1.1 A private network per cage: `enter` gains a flag naming a bridge and
  the cage's address on it, gets a veth, and has no other interface.
- 1.2 A flag that suppresses the nix daemon socket bind.
- 1.3 Lock bump here; `seam.bats` updated for both flags and for `--subject`
  leaving. Exit: seam green on `main` with the new line.

## Phase 2: the machine, on the branch

- 2.1 A generated machine flake per factory under the state directory, the
  worked repository as its input, `flake.lock` pinned per factory.
  `cageworks up` builds from the lock; a bad declaration fails the build.
  Each role's devShell resolved at build time with `nix print-dev-env` and
  handed to the session as environment.
- 2.2 Guest services: Forgejo on a `recordQuota` dataset; Valkey with no
  persistence and ACL users set at boot from per-role secrets; the bridge
  with the two rules; the proxy on the bridge address counting tokens per
  source address against the soft and hard limits; probes publishing to the
  `probes` stream.
- 2.3 `cageworks up` idempotent for Forgejo accounts, `read` collaborators,
  `write:issue` tokens, memory issues opened as each role, labels for every
  stage, and ACL users. Second `up` changes nothing.
- 2.4 `tests/manual/isolation.sh` passes: no route off the machine, no
  cage-to-cage, spoofed source dropped, spend on the right address.
- 2.5 `tests/manual/stop-and-start.sh` rerun with Forgejo's data in the
  manifest.

## Phase 3: the TypeScript package, on the branch

One package, built through the flake, tests in its own runner.

- 3.1 Skeleton: the six-verb vocabulary and every bus message as types,
  validators for both, `cageworks.nix` schema mirrored for the executor's
  checks. Exit: a malformed command and a malformed message are refused by
  test.
- 3.2 Extension: `session_start` and `session_shutdown` lifecycle, `ready`
  with capabilities, mailbox subscription with reconnect and re-announce,
  assignment pointer to fresh session, issue read by token, outcome comment,
  memory issue read at start and rewrite at end, `findings:<role>`
  broadcast, turn and tool events to the bus, advisory checks on branch,
  signature and commit. Exit: driven against a stubbed bus and Forgejo.
- 3.3 Executor: reconciliation on start against `assigning` rows; the six
  verbs validated against the declaration; sessions started as
  `nixcage-container enter` argv (seam applies); labels moved on outcome
  after the executor's own commit, signature and namespace check; push and
  pull request on Forgejo; token minting; unit watching; decider restart;
  soft limit stops routing; `mirror` as a server-side verb exporting issues
  to `refs/cageworks/record` and pushing with `main`. Exit: routing model's
  scenarios replayed as tests, including the liar.
- 3.4 Decider: a cage like any other, prompt from the four parts of
  decision 41, read token on Forgejo, typed commands out. Exit: a recorded
  board produces a valid `assign` and an invalid one is refused upstream.
- 3.5 Relay: `cageworks factory watch <factory>` JSONL over ssh, its shape
  written down, one contract test on each side.

## Phase 4: the operator's side, on the branch

- 4.1 `cageworks` reduced to the launcher of decision 53: `up`, `down`,
  `vm status`, `factory mirror`, `factory watch`, `task file`, `role stop`.
  Deleted with their tests: `task-store.sh`, `record.sh`, `caps.sh`,
  `integrate.sh`, `journal.sh`, `factory-clone.sh`, the `role`, `task` and
  `factory` verbs they served, herdr and `--pane`, `journalQuota`.
- 4.2 TUI on the operator's host: roles and state, stages as label columns,
  live stream, steer, file, block, retry, stop, mirror, memory view, pull
  requests, budget per role and decider. Exit: every verb the factory offers
  is reachable from it without the web UI, merge excepted.

## Phase 5: parity and merge

- 5.1 `tests/manual/parity.sh` passes on a real machine: goal filed, assigned
  by the decider, worked, tested by the testing capability, pull request
  opened, mirrored, no command typed after the goal.
- 5.2 Models green; `task-claim.qnt`, `egress-authority.als`,
  `ledger-tap.qnt` and `factory-lifecycle.qnt` deleted.
- 5.3 `docs/architecture.md` rewritten from the branch; `CLAUDE.md` follows.
- 5.4 Branch merged to `main`. This file deleted, its content in `docs/`.

## Where the log's open items land (REDESIGN-LOG.md section 6)

Relay shape: 3.5. Record export format and re-import: 3.3, with re-import
in 2.3. `probes` cap and the proxy log's place: 2.2. Re-announce after a
Valkey restart: 3.2. `cageworks up` idempotency: 2.3. Origin ref acceptance
on non-Forgejo forges: 5.1, measured against the real origin.
