# Roadmap

The steps from the design that runs today (`docs/architecture.md`) to the one
ADR-033 through ADR-040 and PRD-006 decide. Decision numbers below refer to
`REDESIGN-LOG.md`, which those documents supersede and which keeps the
reasoning until phase 5.4.

No docmeta frontmatter on purpose: this is a plan, not a decision, and
`docmeta-tracker` should not index it. PRD-006 (phase 0.5) will carry these
phases as its own, and this file then points at it.

Status is kept here, one line per item, edited when an item's exit holds.
Nothing below is started as of 2026-09-12.

## Method

Every component is built behaviour first. Before the code of any item in
phases 1 to 4, its behaviours are written as Given/When/Then scenarios in
the test runner that component uses, run, and seen failing for the right
reason; the code then makes them pass and nothing more. Shell components use
bats with test names that read as the scenario; the TypeScript package uses
its own runner with the same three-part naming; what needs a real machine is
a script under `tests/manual/` whose steps are the scenario. A boundary
between two components gets a contract test on each side, written the same
way. The formal models are dropped from this plan: items 0.1 and 0.2 are
withdrawn and 0.3 and 5.2 reduced to what the models already say.

Ordered by dependency. Nothing in a phase starts before the previous phase's
exit holds, except phase 1, which is upstream and runs beside phase 0. Every
item names what exists when it is done; "written" means committed and green.

## Phase 0: gates, on `main`

The parity bar and the models exist before the branch does (decisions 37
and 38, section 4).

- 0.1 Withdrawn. The routing protocol's scenarios (crash, stall, a liar at
  reconciliation, `assigning` before send, `assigned` on ack) are the
  executor's own scenarios in 3.3.
- 0.2 Withdrawn. What it would have stated is stated as scenarios in 2.2
  (bridge rules, spend attribution), 2.3 (tokens, memory issues, labels) and
  3.3 (board rows, capability checks).
- 0.3 `models/vm-lifecycle.qnt` amended: rebuild is the normal path, drain is
  per task. Exit: green. Done 2026-09-12: `allInvariants` ok, three
  witnesses violate as they must.
- 0.4 Decision 48 amended to the TUI scope decision 53 implies. Done
  2026-09-12.
- 0.5 ADRs and a PRD, through `adr-write` and `prd-new`: one ADR per
  reversal in section 3, amendments to the ADRs that stand, PRD-006 carrying
  this roadmap as its phases. `docmeta-tracker docs` regenerated. Exit: this
  file is redundant and says so at its top. Done 2026-09-12: ADR-033 to
  ADR-040, PRD-006; ADR-011, 021, 022, 024, 025, 026, 027, 028 and PRD-005
  superseded.
- 0.6 `tests/manual/parity.sh` written as a script that fails: the journey
  of decision 38 as steps with a check each, and `tests/manual/isolation.sh`
  with the two bridge rules and spend attribution. Exit: both run and fail
  for the right reason on today's machine. Written 2026-09-12, with
  `tests/manual/lib.sh` holding what every proof shares. The run is
  blocked: `cageworks up` fails on this host in microvm.nix's
  `microvm-store-disk.erofs` (mkfs.erofs under bubblewrap cannot open
  `nixos-tmpfiles.d/lib`, and the copy fallback is refused), which is
  upstream of everything here. Unverified on a machine until that builds.

## Phase 1: nixcage interface, upstream

Two commits in two repositories and a lock bump each (ADR-018).

- 1.1 A private network per cage: `enter` gains a flag naming a bridge and
  the cage's address on it, gets a veth, and has no other interface. Done
  2026-09-12: nixcage ADR-011, `--network <bridge>:<addr>/<prefix>`.
- 1.2 A flag that suppresses the nix daemon socket bind. Done 2026-09-12:
  `--no-nix-daemon`, refused beside `--shell`.
- 1.3 Lock bump here. Exit: the suite green on `main` with the new lock,
  which it is because both options default off. Done 2026-09-12: nixcage
  `3c1a018`, 435 tests green. The session line itself changes on the branch
  in 2.2, together with the bridge it names, and `seam.bats` asserts the new
  line there; changing it on `main` would point a role at a bridge no
  machine has yet.

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
  to `refs/cageworks/record` and pushing with `main`. Exit: the routing
  scenarios of 0.1 pass as tests, including the liar.
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
- 5.2 `factory-structure.als` and `vm-lifecycle.qnt` green or deleted with
  a reason; `task-claim.qnt`, `egress-authority.als`, `ledger-tap.qnt` and
  `factory-lifecycle.qnt` deleted.
- 5.3 `docs/architecture.md` rewritten from the branch; `CLAUDE.md` follows.
- 5.4 Branch merged to `main`. `REDESIGN-LOG.md` deleted, its content in
  `docs/`; this file stays and points at PRD-006.

## Where the log's open items land (REDESIGN-LOG.md section 6)

Relay shape: 3.5. Record export format and re-import: 3.3, with re-import
in 2.3. `probes` cap and the proxy log's place: 2.2. Re-announce after a
Valkey restart: 3.2. `cageworks up` idempotency: 2.3. Origin ref acceptance
on non-Forgejo forges: 5.1, measured against the real origin.
