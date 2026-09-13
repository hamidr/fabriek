# Roadmap

The steps from the design that ran before the redesign to the one ADR-033
through ADR-041 and PRD-006 decide; `docs/architecture.md` is what runs
now. Decision numbers below refer to `REDESIGN-LOG.md`, the working log
those documents superseded and phase 5.4 deleted; it is in the history
before that commit for anyone who wants the reasoning as it was written.

No docmeta frontmatter on purpose: this is a plan, not a decision, and
`docmeta-tracker` should not index it. PRD-006 carries these phases as its
own; this file is the status beside each.

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
  blocked: `fabriek up` fails on this host in microvm.nix's
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
  `fabriek up` builds from the lock; a bad declaration fails the build.
  Each role's devShell resolved at build time and handed to the session as
  environment. Done 2026-09-12 on the branch: `modules/machine-spec.sh`
  composes the spec inside a derivation from the same validators, and
  `lib.factory` realises each role's devShell inputs into a profile at
  `/etc/fabriek/roles/<role>/profile` (its `buildInputs`, not
  `print-dev-env`: there is no shell to run a hook in). The clamped
  declaration lands at `/etc/fabriek/declaration.json`; the machine program
  starts reading it there in 4.1, when the executor does (3.3). 450 tests
  green.
- 2.2 Machine services: Forgejo on a `recordQuota` dataset; Valkey with no
  persistence and ACL users set at boot from per-role secrets; the bridge
  with the two rules; the proxy on the bridge address counting tokens per
  source address against the soft and hard limits; probes publishing to the
  `probes` stream. Done 2026-09-12 on the branch, one module per service
  under `modules/machine/`, evaluated by `tests/command/machine_services.bats`.
  Decided here: the `probes` stream is capped at 10000 entries; the proxy's
  metadata log stays in the machine's journald, on the default namespace;
  the proxy counts with njs in nginx's memory, so a restart is a spend
  nobody remembers, accepted because the ceiling bounds a runaway rather
  than keeping an account; the cage is named after its role and a role name
  is at most twelve characters, because nspawn names the veth after the
  cage. The session line changed with it: `--network`, `--no-nix-daemon`
  and the profile on `NIXCAGE_PATH_PREFIX` in, `--subject`, `--shell` and
  the journal bind out; `seam.bats` asserts the new line. The machine has
  not booted with any of this: the erofs builder failure of 0.6 stands.
- 2.3 `fabriek up` idempotent for Forgejo accounts, `read` collaborators,
  `write:issue` tokens, memory issues opened as each role, labels for every
  stage, and ACL users. Second `up` changes nothing. Done 2026-09-12 on the
  branch: `fabriek-container factory-prepare`, run by `up` once the
  machine holds its credential, with `modules/forge.sh` and `modules/bus.sh`
  behind it and `tests/command/prepare.bats` driving a stubbed forge twice.
  A stage's label is its capability's name. The record's re-import from
  `refs/fabriek/record` landed 2026-09-13: on a board with no issue at
  all, prepare reads `issues.json` off origin and opens each issue again in
  number order with its labels and state, memory issues excepted (each is
  opened as its role), naming a label the declaration no longer has. The
  numbers are the forge's and not promised; comments are not in the export
  and so not restored.
- 2.4 `tests/manual/isolation.sh` passes: no route off the machine, no
  cage-to-cage, spoofed source dropped, spend on the right address.
  Done 2026-09-12 on a machine, after seven findings it forced: the loop
  bound as symlinks into an /etc the cage lacks, the firewall closed on the
  bridge, rules keyed on `ve-` where nspawn names `vb-`, the decider's
  credentials left root's, a hand's command replaced by the declared one,
  an existing account refused as an error, and profiles made of dev
  outputs. The two Thens that read the proxy's count are gated on a real
  credential and say so; the proof stops the executor for its duration
  because a role's cage name and address are taken while the executor
  runs it (`docs/architecture.md`, gaps).
- 2.5 `tests/manual/stop-and-start.sh` rerun with Forgejo's data in the
  manifest. Done 2026-09-12: an issue opened through the forge before the
  first stop was on the board after each of ten stop and start cycles,
  alongside the 300-file manifest; down 5 to 26 seconds, up 28 to 245
  seconds on this host's linux builder.

## Phase 3: the TypeScript package, on the branch

One package, built through the flake, tests in its own runner.

- 3.1 Skeleton: the six-verb vocabulary and every bus message as types,
  validators for both, `fabriek.nix` schema mirrored for the executor's
  checks. Exit: a malformed command and a malformed message are refused by
  test. Done 2026-09-12 on the branch: `factory/`, built by the flake with
  `tsc` and tested with node's own runner, no npm and no lockfile; pi's
  types and `@types/node` are linked in from the pi already in the closure.
  `names.ts`, `vocabulary.ts`, `messages.ts`, `declaration.ts`, 25
  scenarios green, `nix build .#factory` runs them.
- 3.2 Extension: `session_start` and `session_shutdown` lifecycle, `ready`
  with capabilities, mailbox subscription with reconnect and re-announce,
  assignment pointer to fresh session, issue read by token, outcome comment,
  memory issue read at start and rewrite at end, `findings:<role>`
  broadcast, turn and tool events to the bus, advisory checks on branch,
  signature and commit. Exit: driven against a stubbed bus and Forgejo.
  Done 2026-09-12 on the branch: `factory/src/extension/actor.ts` is the
  loop against three interfaces, 14 scenarios on fakes; `index.ts` binds
  it to pi, a RESP client and a forge client each tested against a local
  fake. A fresh session is a fresh process (ADR-035 point 4 amended), the
  outcome is a `report_outcome` tool the agent calls, memory an
  `update_memory` tool. The machine carries the extension and a
  `models.json` under `/etc/fabriek/pi` (`machine/floor.nix`), and a
  supervised session is handed them with its two credentials and its
  environment (`seam.bats`).
- 3.3 Executor: reconciliation on start against `assigning` rows; the six
  verbs validated against the declaration; sessions started as
  `nixcage-container enter` argv (seam applies); labels moved on outcome
  after the executor's own commit, signature and namespace check; push and
  pull request on Forgejo; token minting; unit watching; decider restart;
  soft limit stops routing; `mirror` as a server-side verb exporting issues
  to `refs/fabriek/record` and pushing with `main`. Exit: the routing
  scenarios of 0.1 pass as tests, including the liar. Done
  2026-09-12 on the branch: `factory/src/executor/core.ts` against five
  interfaces, 20 scenarios including the crash between board write and
  send, the stall and the liar; adapters for the forge, the bus, sessions
  and git; `main.ts` as the `fabriek-executor` unit, which publishes the
  board and the spend to `events:executor` for the relay. The operator
  writes through it: `task-file`, `role-stop`, `role-steer`,
  `factory-mirror` and `factory-send` put one entry on the `operator`
  stream as the executor's bus user, title and body as files. The export is
  `issues.json` on `refs/fabriek/record`; prepare reads it back (2.3).
- 3.4 Decider: a cage like any other, prompt from the four parts of
  decision 41, read token on Forgejo, typed commands out. Exit: a recorded
  board produces a valid `assign` and an invalid one is refused upstream.
  Done 2026-09-12 on the branch: `decider/core.ts` renders the four parts
  (7 scenarios) and gates every tool call through the vocabulary and the
  declaration; `decider/index.ts` runs it as a pi extension in its own
  cage, named `decider`, which the declaration may not use; the policy
  file is `decider.policy` in `fabriek.nix`, baked into the image and
  bound read-only.
- 3.5 Relay: `fabriek factory watch <factory>` JSONL over ssh, its shape
  written down, one contract test on each side. Done 2026-09-12 on the
  branch: one JSON object per line, `stream`, `id`, `fields` as the bus
  holds them; `relay/fixtures.json` is the contract, read by the relay's
  test and the TUI's model test alike.

## Phase 4: the operator's side, on the branch

- 4.1 `fabriek` reduced to the launcher of decision 53: `up`, `down`,
  `vm status`, `factory mirror`, `factory watch`, `task file`, `role stop`.
  Deleted with their tests: `task-store.sh`, `record.sh`, `caps.sh`,
  `integrate.sh`, `journal.sh`, `factory-clone.sh`, the `role`, `task` and
  `factory` verbs they served, herdr and `--pane`, `journalQuota`. Done
  2026-09-12 on the branch, pulled forward into 3.3 because a dispatch test
  couples the CLI's verbs to the machine's. `factory-clone.sh` stays: the
  machine still clones origin and cuts worktrees from it. The CLI gained
  `role steer`, `factory send` and `factory console`.
- 4.2 TUI on the operator's host: roles and state, stages as label columns,
  live stream, steer, file, block, retry, stop, mirror, memory view, pull
  requests, budget per role and decider. Exit: every verb the factory offers
  is reachable from it without the web UI, merge excepted. Done 2026-09-12
  on the branch for what the relay carries: `tui/model.ts` folds relay
  lines (pure, tested on the fixture), `tui/view.ts` renders (tested),
  `tui/main.ts` reads `fabriek factory watch` and writes through the
  CLI; keys file, steer, stop, retry, block, push and mirror. Not yet on
  it: a memory view and the pull request list, which are the forge's and
  not on the bus; the board reaches the TUI as the executor's `board`
  event. `fabriek factory console <factory>` starts it.

## Phase 5: parity and merge

- 5.1 `tests/manual/parity.sh` passes on a real machine: goal filed, assigned
  by the decider, worked, tested by the testing capability, pull request
  opened, mirrored, no command typed after the goal.
  Run 2026-09-12 as far as a credential allows: the board, the executor,
  the decider's cage, and a goal filed from the operator's host reaching
  the board with its first stage's label all pass; assignment and
  everything after are gated on a credential the endpoint accepts, and the
  proof says so and stops. The proof reads the machine as built: the forge
  on the bridge, the decider as a session the executor starts, the stages
  from the spec, the issue by its title, routing off the relay.
  2026-09-13: the journey after the assignment passes on this host with
  scripted actors in place of pi (`tests/system/journey.sh`): assigned,
  acked, worked, moved, closed; a done with no commit refused; a failed
  task retried by the same role; push to a pull request; mirror to origin;
  ACL DRYRUN per bus user. Six defects found and fixed on the way, each
  one the machine would have hit: the ready race at the executor's start,
  the missing `assigning`/`assigned` labels, no `main` on the forge, the
  executor's comments never read as its own, done accepted on an earlier
  task's commit, attempts counted per task rather than per stage. What
  still needs a machine and a credential: the cage, the bridge, the
  proxy's count, and pi itself.
- 5.2 `factory-structure.als` and `vm-lifecycle.qnt` green or deleted with
  a reason; `task-claim.qnt`, `egress-authority.als`, `ledger-tap.qnt` and
  `factory-lifecycle.qnt` deleted. Done 2026-09-12: `vm-lifecycle.qnt`
  stays and is green; the other five are deleted. `factory-structure.als`
  modelled the shared ref spaces, the claim and the ledger, all gone, and
  what it would have said about the new design is said by scenarios
  instead (the Method section): the executor's on the board rows and the
  capability checks, `seam.bats` on the ref partition and the session,
  `machine_services.bats` on the bridge rules and the bus ACLs,
  `prepare.bats` on the tokens and the memory issues.
- 5.3 `docs/architecture.md` rewritten from the branch; `CLAUDE.md` follows.
  Done 2026-09-12, `README.md` with them.
- 5.4 Branch merged to `main`. `REDESIGN-LOG.md` deleted, its content in
  `docs/`; this file stays and points at PRD-006.
  Done 2026-09-12, with 5.1 gated as recorded above: the operator chose
  to merge with the gate written down rather than hold the branch for a
  credential.

## After the merge

- 6.1 `tests/manual/specialist.sh` passes on a real machine: in the
  example's backend cage, java on PATH with the floor under it, the
  specialists' prompt where pi appends it, the skill where pi discovers
  skills (ADR-042). Everything else of ADR-042 is asserted on this host by
  `catalogue.bats`, `factory_flake.bats`, `machine_services.bats` and
  `seam.bats`. Not run as of 2026-09-13.
- 6.2 The same proof's language-server scenario (ADR-043): lsp.json where
  pi-lsp reads it, the binary in the cage, and with a model, diagnostics
  appended after a write. Not run as of 2026-09-13.
- 6.3 The same proof's guard scenario (ADR-044): tests.json where the loop
  reads it, and with a model, an edit without a test refused with
  guard_refused on the bus. Not run as of 2026-09-14.

## Where the log's open items landed (its section 6)

Relay shape: 3.5. Record export format and re-import: 3.3, with re-import
in 2.3. `probes` cap and the proxy log's place: 2.2. Re-announce after a
Valkey restart: 3.2. `fabriek up` idempotency: 2.3. Origin ref acceptance
on non-Forgejo forges: 5.1, measured against the real origin.
