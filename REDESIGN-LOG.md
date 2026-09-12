# Redesign decision log

A brainstorming session on 2026-09-10 and 2026-09-11 re-derived cageworks from
its assumptions, and a second session on 2026-09-11 closed the questions the
first left open (decisions 39 to 50). A soundness review on 2026-09-12 amended
decisions 21, 35 and 45 in place and added decision 51. This file records what
was decided, why, and what each choice reverses. It is deliberately not an ADR
or a PRD: it carries no docmeta frontmatter and lives outside `docs/` so
`docmeta-check` does not read it. It exists so the session's reasoning is not
lost while the document shape is still undecided.

Nothing here is implemented. `docs/` still describes the design that runs
today, and several documents there are contradicted by this file. Where they
disagree, `docs/` is what the code does and this file is what was agreed.

## 1. The design as decided

### Machine

One NixOS microVM per factory, on Linux and macOS alike, with a ZFS pool per
factory and a keypair and forwarded port per factory. ADR-019 stands
unchanged.

The factory declaration is built into the machine image rather than read at
run time. Each factory gets a generated machine flake under its own state
directory whose input is the worked repository, with the rev pinned in that
factory's own `flake.lock`. `cageworks up` builds from the lock, and updating a
role is a lock bump and a rebuild. Which declaration a run used is the image's
identity rather than a fact recorded beside the work, and reproducing a run
means checking out a lock.

Each role's devShell is resolved at build time (`nix print-dev-env`) and handed
to the session as environment, because a cage can no longer run `nix develop`.

### Inside the guest, uncaged

- **The executor.** Holds every credential. Starts and stops sessions, moves
  issues between columns, pushes branches, mints Forgejo tokens, manages
  Valkey ACLs, watches units, counts tokens, mirrors the record. It decides
  nothing. Written in TypeScript, in the one package that also holds the
  extension, so the command vocabulary and the bus message types are defined
  once and imported by both ends.
- **Forgejo.** The task board and the factory's own forge: issues with labels
  and project columns, per-role accounts with scoped tokens, pull requests,
  and a web UI the operator reaches over the already-forwarded ssh port.
- **Valkey.** The message bus. A mailbox stream per actor, an ACL user per
  role. No persistence.
- **The egress proxy.** Holds the model credential, injects it at egress,
  counts tokens per role and per factory.
- **Kernel probes.** `sched_process_exec`, `sched_process_exit`, socket
  connect.

### Inside the guest, caged

One cage per role, plus one for the decider. A cage is an actor: pi plus a
TypeScript extension of ours, loaded by pi's `jiti`, which is the loop.

An actor announces `ready` with the capabilities its role provides, receives an
assignment pointer on the bus, reads the issue from Forgejo, works, commits,
comments its outcome on the issue under its own token, and announces `ready`
again. The executor checks the outcome against what is checkable and moves the
column; the decider only reads outcomes (decision 40).

A cage reaches Forgejo, Valkey and the proxy over the factory's internal
network and has no route off the machine. It holds no model credential, no
forge repository credential, no nix daemon socket and no web access. Its
Forgejo token is scoped to issues and comments only.

A role's uid, home and signing key are permanent. Its worktree is an ordinary
directory, created and destroyed per task, inside the role's one quota'd
dataset.

### The decider

A caged actor like any other, provided by the machine rather than declared by
the repository. It reads Forgejo, the bus and the declaration, and decides who
gets what next, whether a failure is worth retrying, whether a task is
hopeless, whether something should be filed or blocked.

It acts only by asking the executor, through a closed vocabulary of six typed
commands (assign, retry, block, file, push, stop; decision 39). Its prompt is
the machine's system prompt, the declaration and the board rendered as data,
the `ready` set from the bus, and one policy file the repository declares
(decision 41). The executor refuses
anything the declaration does not permit: a role that does not exist, a
capability that role does not provide, an attempt past the declared limit, a
branch outside `refs/heads/<role>/`, anything touching `main`, a spend past the
ceiling. The decider has read access to Forgejo and no write token.

### Work

An actor announces `ready`. The decider chooses. The executor records the
assignment on the board as `assigning`, then sends the pointer; the actor's
ack moves it to `assigned`. On startup the executor reconciles before routing
anything: it asks every live actor what it holds, and uses the answers only to
resolve `assigning` rows to `assigned` or back to unassigned. An answer never
creates an assignment the executor did not record, because under the threat
model an answer is a claim. An actor that does not answer within a timeout is
unknown rather than free, and its tasks stay unrouted.

An actor that cannot finish blocks in place: it keeps its task and its
worktree, comments that it is blocked, and simply never announces `ready`;
the executor labels the issue, because a role token cannot. Capacity at a
capability is added by declaring another role (ADR-015 pt2).

Testing is a capability a role provides, assigned like any other work. There is
no CI service and no runner.

The agent makes its own commits and chooses its own boundaries and messages.
The extension authors none, and enforces only what is checkable: the branch is
the role's own namespace, the signature is the role's key, and at least one
commit exists before an outcome is reported as done.

Peers may broadcast to `findings:<role>`, writable by that role alone so
attribution is the ACL's rather than the message's, and readable by all. Work
always routes through the decider and the executor.

### Context

The pi process is long-lived and the extension with it. Each task gets a fresh
session, so context does not bleed between unrelated tasks. The role's home
persists, but the role memory does not live there: it is the body of one
pinned issue per role on Forgejo, labelled `memory`, opened by the role itself
at `cageworks up` so the role is its poster and may edit it. The extension
reads it at session start and rewrites it at session end. The operator reads
and clears it in the same UI as everything else, and the edit history is the
audit (decision 43). Nothing conferring authority may live in it.

### Integration

The executor pushes role branches to Forgejo and opens the pull request there.
Review happens in the guest. Merging is the operator's click in Forgejo's UI:
no verb merges, so the executor's refusal of anything touching `main` stays
literal and factory autonomy ends at an open, tested pull request. The
executor mirrors merged `main` onward to origin, and with it the record:
Forgejo's issues and comments exported as JSON under `refs/cageworks/record`
(decision 46). The mirror is an operator action, `cageworks factory mirror`,
not a reaction to the merge event, so nothing leaves the machine until the
operator says so and PRD-003's criterion that a bad merge is recoverable with
nothing outside having seen it is restored.

### Control and cost

The operator reads the bus directly, so watching survives a dead executor, and
writes through the executor, so every intervention is recorded. Stopping works
over ssh without the executor. The operator's client is a TUI of ours, running
on the operator's host: it reads a JSONL relay of the bus over the machine's
ssh port and writes through the `cageworks` CLI (decisions 48 to 50). Forgejo's
web UI over the same port is the board, the pull requests and the role
memories. Mid-turn steering reaches the extension's inbox and becomes
`pi.sendMessage()` with delivery `steer`, which queues into the running turn at
the next tool boundary.

The proxy counts input and output tokens per role and per factory against a
ceiling the factory declares and the operator caps. At the soft limit the
executor stops routing new work and running turns finish. At a hard limit above
it the proxy refuses, so a runaway cannot outspend the cap with one long turn.
This is the only hard cost control; the self-checked budget of ADR-021 pt5 was
deleted with the threat model.

### Observation

Three sources, never merged: the Forgejo thread is what a role said it did, the
proxy is what it spent, the kernel probes are what it ran. Nothing persists the
turn and tool event stream; the extension still publishes those to the bus,
because that is what the operator watches live, and nothing writes them down.
pi's own session directory holds the verbatim transcript on the role's own
storage. The kernel probes publish to a capped `probes` stream on the bus,
keyed by uid and written by the machine rather than by any role, and are
persisted no more than the turn events are (decision 44).

### Network

A per-factory internal bridge. Each cage gets its own veth and its own address.
Two rules are load-bearing rather than incidental:

1. The host side drops any packet whose source is not that cage's assigned
   address. Spend attribution is by address, so without this rule a cage can
   bill a peer.
2. The bridge permits cage to Forgejo, Valkey and proxy, and drops cage to
   cage.

This is ADR-025's packet filter returning on the internal bridge instead of on
egress: a different table, the same kind of mechanism. Whatever replaces
`tests/manual/egress.sh` has to check both rules.

## 2. Decision log

Listed in the order decided. Several early answers were superseded later in the
same session; the final position is what section 1 describes, and the
supersessions are noted.

1. **Threat model: hostile, stated.** An agent may try to escape, exfiltrate
   and forge. Keep the VM per factory and the uid partition; delete every
   mechanism that only works if the agent cooperates. Consequence: the budget
   moves to the proxy, an agent-written record is not evidence, and
   `PI_OFFLINE` is not a control.

2. **Record: git-bug, kept.** *Superseded twice.* Later moved to forge issues,
   returned to git-bug under the actor model, and finally became Forgejo in the
   guest (decision 22).

3. **Scheduling: self-take, as ADR-021.** *Superseded by decision 19*, then by
   decision 26. The final answer is a caged decider and an uncaged executor.

4. **Claims: per-role namespaces on git refs.** *Superseded by decision 19*,
   which deleted the claim protocol entirely. Recorded because the reasoning
   still applies if a claim protocol is ever needed again: per-role namespaces
   trade one atomic compare-and-swap for a distributed mutual-exclusion
   protocol resolved read-side, which is strictly harder to prove and is the
   shape ADR-024 was written about.

5. **Workspace: role permanent, worktree per task.** Discarding the workspace
   is the rollback ADR-017 pt5 refused to offer, and the objection there
   (index and HEAD on another dataset) does not apply when the operation is
   destroy rather than revert.

6. **Agent: pi, pinned.** ADR-029 unchanged. ACP was examined and rejected on
   a measured ground rather than an assumed one: its client-to-agent surface is
   `session/prompt`, `session/cancel`, `session/load`, `session/set_mode`,
   `session/close` and `$/cancel_request`, with no method that injects a
   message into a running turn. ADR-026 pt4's `steer` has no ACP equivalent.
   pi speaks ACP only through third-party adapters that spawn `pi --mode rpc`
   anyway; native support is an unanswered request
   (`earendil-works/pi` discussion #4444, latest comment 2026-07-09).

7. **Bus: Valkey, control plane only.** Valkey rather than Redis because
   Valkey is BSD-3 and Redis' server is not, which is ADR-029's own licence
   argument applied consistently. Scope later grew to carry assignment
   pointers and findings, and briefly the work queue and claims
   (decision 20), which decision 26 removed again. No persistence: state that
   matters is on the board.

8. **Bus access: a Valkey ACL user per role**, password delivered by ADR-009's
   mechanism, generated per role at `cageworks up` and `ACL SETUSER`'d at boot,
   so rotation is a restart and no bus secret exists at rest. The ACL must be
   default-deny (`resetkeys resetchannels nocommands`, then the handful of
   stream verbs), or `EVAL`, `CONFIG`, `ACL` and `SCAN` hand a role back what
   the patterns took away. Revoking a role now deletes three things: its
   signing key, its `allowed_signers` line, and its ACL user.

9. **The loop runs inside pi, as a rich extension.** Recorded with the
   objection stated and overruled: this spends ADR-028, because loop and agent
   become one process under one uid, so ADR-027 pt4's promise that a role
   cannot lie about who it is does not hold for anything the loop writes, and
   the budget must therefore live at the proxy. What it buys is that
   `--mode rpc` gives the loop both the event stream and `steer`, `follow_up`
   and `abort` already, and the extension surface is richer:
   `pi.registerCommand()`, `pi.registerFlag()`, the full event set including
   `tool_call` and `tool_result`, and `pi.sendMessage()` with delivery `steer`.
   Background resources must start at `session_start` and be torn down at
   `session_shutdown`. There is no API stability statement.

10. **The extension joins ADR-030's floor.** It cannot come from the project's
    flake, for ADR-030's own reason: a repository that forgets it is a factory
    whose roles do not start, and the operator cannot repair that from where
    they are standing. It ships with the machine, in the configuration
    directory `PI_CODING_AGENT_DIR` already names, bound read-only. ADR-029
    pt3 hardens from "a role naming something else is undefined" into a real
    restriction: the loop is a pi extension, so a role runs pi or has no loop.

11. **Spend attribution: unix socket per role with `SO_PEERCRED`.**
    *Superseded by decision 24*, which moved it to per-cage addresses with a
    source-address rule. The reasoning is kept because it is why decision 24
    needs that rule at all.

12. **Network: private per cage.** Deletes ADR-025's uid filter, declared proxy
    uid and `/etc/resolv.conf` arrangement, and `models/egress-authority.als`
    with them. A role is denied the network by not having one, which is the
    only kind of denial that cannot be misconfigured. Costs an interface change
    in nixcage. Later refined by decision 24 into a per-factory internal
    bridge.

13. **Integration: push branches to origin, review on the forge.**
    *Superseded by decision 23.* Deleted `modules/integrate.sh` and the local
    `main` advance either way.

14. **Machine: microVM per factory.** ADR-019 stands.

15. **Declaration: built into the image**, evaluated from the worked repository
    as a flake input with a per-factory lock. Withdraws ADR-020 pt3 and pt3a.
    Validation moves to build time, so a bad declaration fails the build rather
    than the first command that needs it, and devShells can be pre-built into
    the store overlay. Adding a role becomes a rebuild and a restart, so
    ADR-019's "stale" state in `models/vm-lifecycle.qnt` becomes the normal
    path. What has to drain before a restart is a task, not a role: a
    worktree is per task inside the role's permanent dataset (decision 5), so
    an actor mid-task is stopped and its task retried, and nothing permanent
    is lost.

16. **Take mechanism: Valkey sorted set, `ZPOPMIN`.** *Superseded by decision
    19.* Noted for one thing it revealed: a sorted set has a score, so priority
    is available for free if PRD-005's non-goal is ever reopened.

17. **Liveness: held state on the board, recovery by watching the unit.**
    *Folded into decision 21.* The accepted gap survives: a hung-but-alive
    actor holds its task forever, which a renewed lease would also miss.

18. **Forge for origin: push only, no platform API.** No `gh`, no abstraction.
    The forge credential for origin collapses to an ordinary git push
    credential. Still true after decision 23, which puts the API-using forge
    inside the guest.

19. **The actor model.** Each cage is an actor, Valkey is the message bus, the
    supervisor holds the board, and an actor that announces itself free is sent
    work. This is the session's largest simplification. It deletes the entire
    take protocol: no claim refs, no namespaces, no read-side resolution rule,
    no lease, no renewal-moves-the-ref, no all-zeros footgun, no `ZPOPMIN`, no
    per-capability streams, no sweeper, and no files-ref-backend requirement.
    Mutual exclusion becomes a property of there being one sender. PRD-003's
    proudest property returns: no run is ever started by a cage. PRD-005's
    first non-goal is reversed, and what saves it is that a router judges
    nothing, until decision 26 made the router smart on purpose.

    It also dissolved all of ADR-024 while git-bug was still the board:
    git-bug's exclusive repository lock, its lock-removal race and its silently
    corrupting search index were only fatal because ADR-022 made every role a
    writer. One writer is ADR-013 pt2's original design.

20. **Routing: oldest ready first, FIFO per capability.** *Superseded by
    decision 26*, which replaced the rule with judgement. Recorded because it
    remains the obvious fallback if the decider is ever made advisory.

21. **Delivery: record intent, send, confirm on ack.** *Amended 2026-09-12.*
    As first decided, the executor sent and recorded on ack, and a startup
    reconciliation asked every live actor what it held and corrected the board
    from the answers. That trusted a cage's word, which decision 1 forbids: an
    actor could assert a task it was never sent or deny one it holds. Now the
    executor writes `assigning` to the board before it sends, and the ack moves
    the row to `assigned`. Reconciliation resolves `assigning` rows only,
    taking an actor's answer as one input, and never creates an assignment
    from an answer. The crash window between write and send resolves the same
    way: an `assigning` row with no ack is re-sent or released, never
    duplicated. `models/routing.qnt` must include an actor that lies at
    reconciliation, not only one that crashes.

22. **Peers: broadcast findings, route work.** A findings stream per role,
    writable by that role alone because Valkey does not stamp the writing user
    into a stream entry. Work always routes through the supervisor.

23. **Workflow: ADR-015 stands, except point 3.** Workflows, stages, `ready`,
    `done` and `consults` stay in the declaration, validated at build time.
    Point 3 (the first idle capable role in declaration order takes the task)
    is replaced by the decider's judgement under decision 28. This is the
    operator's policy lever, and it is what stops a role routing work to itself
    forever.

24. **Payload: inline on the bus, bounded.** *Refined by decision 27*: once the
    board became readable by every actor, the assignment carries a pointer and
    the actor reads the issue.

25. **Operator: reads the bus directly, writes through the supervisor.**
    Watching survives a dead supervisor; every intervention is recorded;
    stopping works over ssh independently.

26. **Blocking: block in place.** An actor keeps its task and its worktree and
    never announces `ready`. Withdraws PRD-003's clause that a waiting run
    "holds no concurrency while it waits". The remedy is ADR-015 pt2: declare
    another role. The operator needs a "who is blocked on me" view, because a
    task blocked forever is a role gone forever.

27. **Sessions: fresh per task, plus a role memory** in the persistent home.
    The pi process outlives any one task because the extension has to hold the
    mailbox subscription and announce `ready`.

28. **The supervisor is itself a caged actor, so it splits in two.** A caged
    **decider** that reads and judges, and an uncaged **executor** that acts
    and decides nothing. This deliberately drops one of the two invariants that
    held the old design up: "the supervisor is uncaged and content-blind"
    becomes "the executor is uncaged and content-blind, the decider is caged
    and reads everything". The other invariant gets more load-bearing, not
    less: nothing a role writes may reach a command line, and that now governs
    the decider's output, because the decider's decisions drive the thing
    holding the credentials.

    The decider is machine-provided rather than declared, for ADR-030's reason.
    It runs a model, so the supervisor's own thinking is a budget line. A dead
    decider is a stopped factory, which the executor restarts.

29. **Authority: a closed vocabulary, validated by the executor.** Typed
    commands only, and the executor refuses whatever the declaration does not
    permit. Retry becomes the decider's judgement bounded by the declared
    attempt limit. A retry's brief includes the previous attempt's outcome.

30. **The board is Forgejo in the guest.** Every actor reads it; only the
    supervisor creates and assigns; access is limited per role by scoped
    tokens. **This fully reverses ADR-013**: there is a shared database, it
    lives on the factory's pool, and the record no longer travels with the
    repository. git-bug leaves the design entirely, taking ADR-022 and ADR-024
    with it. Forgejo's data joins PRD-004 phase 2's pool manifest, and tearing
    a factory down destroys the account of why the code looks as it does unless
    something mirrors it.

    What it buys beyond a board: per-role accounts, so the authorization
    matrix is the service's job; pull requests and review beside the work; and
    a web UI over the forwarded port that is a better operator view than
    anything we would have built. *Amended 2026-09-12:* project columns were
    listed here too, but Forgejo 16 has no repository projects API
    (decision 52), so a stage is a label the executor sets, and the UI's
    column view, if wanted, is a project the operator keeps by hand.

31. **Code flow: role tokens are issue-scoped, the executor pushes.** Roles
    commit locally to their own branch; the executor pushes to Forgejo, opens
    the pull request, and mirrors merged `main` onward to origin. ADR-009
    survives for what it was written about: a role holds no credential that
    can push, pull a private repository, or authenticate outside the machine.
    It does not survive in its exact form, because a role now holds a Forgejo
    token, which is a credential and reaches the factory's own forge, scoped to
    issues and comments. The built ADR-009 is `--no-agent` plus a bound signing
    key; the redesign adds one bounded credential to that.

32. **Transport: everything on the private network, attributed by address.**
    One transport for Forgejo, Valkey and the proxy. Requires the two bridge
    rules in section 1, without which spend attribution is configuration rather
    than proof.

33. **Assignment: the bus carries a pointer, the actor reads the issue.** One
    copy of every fact, in the place the operator also looks, and the thread
    the actor writes back to is the record. The bus keeps the job it is good
    at, which is telling an actor that something changed.

34. **CI: a capability a role provides.** No CI service, no runner. A stage
    names it, a role provides it, the decider assigns it. Forgejo Actions was
    rejected because a runner needs to spawn containers and reach a network,
    which is the isolation model undone for the component running the most
    untrusted code.

35. **Commits: the agent's, with the executor enforcing the boundary.**
    *Amended 2026-09-12.* Deciding what constitutes one logical change is
    judgement and belongs in the cage. The extension checks branch namespace,
    signature, and that a commit exists before a `done` outcome, but it runs
    as the role's uid (decision 9), so its check is advice to the agent and
    not a gate. The executor repeats the same checks before it moves a column
    or pushes (decision 40), and only its verdict counts.

36. **Observation: drop the ledger.** Three sources are the Forgejo thread, the
    proxy and the kernel probes. Deletes most of ADR-027: the tap, the bus
    consumer, the per-factory journal namespace, `resources.journalQuota` and
    `models/ledger-tap.qnt`. Dropping the ledger drops persistence, not the
    event stream: the extension still publishes turn and tool events to the bus
    for the operator to watch live, and nothing writes them down. The first
    source changed character, from journald stamping `_UID` off `SO_PEERCRED`
    to a Forgejo thread written with a per-role token: stronger in that Forgejo
    refuses a role writing as another role, weaker in that a token which can
    comment can usually edit its own comments.

37. **Phasing: greenfield on a branch.** No compatibility work and no
    half-migrated modules. The cost taken on is that the existing suite, which
    is most of what is known to work, stops applying on day one, so the parity
    bar has to exist before the branch does.

38. **Parity bar: one journey, three models, and the isolation proofs.** All on
    a real machine.

    - A goal filed by the operator is assigned by the decider, worked by a
      role, tested by the testing capability, opened as a pull request on
      Forgejo by the executor, and mirrored to origin, with no command typed
      after the goal.
    - `models/routing.qnt`, `models/factory-structure.als` and
      `models/vm-lifecycle.qnt` green. (`task-claim.qnt`,
      `egress-authority.als`, `ledger-tap.qnt` and `factory-lifecycle.qnt`
      are deleted: the last models the task store and the file-based caps,
      both of which leave with decisions 30 and 36; what replaces its
      invariants lives in `routing.qnt`.)
    - A cage has no route off the machine, cannot reach a peer, cannot forge
      its source address, and its spend is attributed to it.

39. **Vocabulary: six verbs, each argument checked against the declaration.**
    `assign <issue> <role>`: the role exists, provides the stage's capability,
    is `ready` on the bus, the issue is in a stage column, and attempts are
    below `taskAttempts`. `retry <issue>`: as `assign`, with the previous
    attempt's outcome attached to the brief. `block <issue> <on-issue>`: both
    exist; a label and nothing else. `file <title-file> <body-file> <stage>`:
    files, never argv, and the stage exists in the workflow. `push <role>`: the
    branch is that role's namespace; opens or updates the pull request.
    `stop <role>`: aborts the current turn, the assignment stays. No verb
    merges and no verb records: those went to the operator (decision 45) and
    to the role (decision 40).

40. **Outcome: the role comments it, the executor moves the column.** `record`
    left the vocabulary because two writers of one outcome is ADR-024's double
    account by another route. The role's comment, under its own token, is the
    outcome; the executor checks what is checkable (a signed commit on the
    role's namespace before `done`) and moves the issue. The decider reads
    outcomes and writes none.

41. **The decider's prompt has four parts and one of them is the
    repository's.** The machine's system prompt (vocabulary, invariants,
    decision rules; ADR-030's floor), the declaration rendered as data, the
    board snapshot (issues by column, assignee, attempts, outcomes) with the
    `ready` set, and one policy file that `cageworks.nix` names, bound
    read-only and appended as a labelled section. The repository states
    priorities and taboos in words; the worst it can do is bad judgement
    inside the declared limits, because the executor validates every verb
    regardless of where the judgement came from.

42. **The executor is TypeScript.** The extension already is, so vocabulary and
    bus message types are one module imported by both ends, and the machine
    already carries node for pi. The cost is that `bats` does not drive this
    component; its tests are in its own toolchain. Bash was refused because
    every command's arguments would pass through shell quoting, which is the
    surface the second invariant exists to keep empty.

43. **Role memory: a pinned `memory` issue per role on Forgejo.** Decision 33's
    principle applied to memory: one copy, where the operator already looks.
    The issue is opened as the role at `cageworks up`, so the role is its
    poster and Forgejo's own rule (a poster edits their own issue) grants the
    edit without a repository-wide write permission that would let a role edit
    a peer's memory. The extension reads the body at session start and rewrites
    it at session end. Clearing is an edit in the UI; the edit history is the
    audit. The file-in-home alternative was refused as a second place to look
    and a second thing to back up.

44. **Kernel probes publish to the bus and persist nowhere.** A `probes` stream
    with a capped length, keyed by uid, written by the machine. The same
    treatment turn and tool events get under decision 36. The third source
    stays independent of every role because no role can write that stream.
    Folding a digest into the outcome was refused because it would route the
    third source through the executor, and journald was refused because a
    small ledger is still a ledger.

45. **Merge is the operator's, and nothing else's.** A human click in Forgejo's
    UI over the forwarded port. The executor's refusal of anything touching
    `main` stays literal. *Amended 2026-09-12:* the mirror to origin was first
    a reaction to Forgejo's merge event, which put a bad merge outside the
    machine within seconds and contradicted the criterion section 1 claims
    restored. It is now an operator action,
    `cageworks factory mirror <factory>`, run through the executor. A `merge`
    verb gated on a review capability was refused because it puts `main` under
    a model's judgement; a per-workflow switch was refused as both, with more
    to model.

46. **The record is mirrored to origin as a ref.** The executor exports
    Forgejo's issues and comments as JSON under `refs/cageworks/record` and
    pushes it beside the merged `main`. The record travels with the repository
    again, read-only, without git-bug. Section 5's "losing the pool loses it"
    narrows to what was not yet mirrored.

47. **`journalQuota` becomes `recordQuota`.** Same slot in
    `modules/resources.sh`, same clamp, new meaning: the dataset Forgejo's data
    lives on. Forgejo's memory comes out of `memory` and gets no line of its
    own. Decision 36's deletion of `journalQuota` becomes a rename.

48. **The operator's client is a TUI of ours.** This reverses ADR-026 pt7. One
    view: roles and their state, board columns, the live event stream, a
    steer box. Roles, columns and memories are already Forgejo's UI, so the
    TUI owes only what Forgejo cannot show: what is happening right now, and
    a way to speak into it.

49. **The TUI runs on the operator's host.** It reads a JSONL relay of the bus
    over the machine's ssh port and writes through the `cageworks` CLI, so
    every intervention still passes the executor. Running it in the guest over
    `nixcage exec --tty` would have kept one package and no relay, and was
    refused because a console that dies with the guest's session is the
    detach problem ADR-026 pt1 removed. Costs: node in the operator's flake,
    and the relay is now an interface to keep.

50. **The CLI keeps the relay as a verb.** `cageworks factory watch <factory>`
    prints the relay's JSONL to stdout. It is what the TUI consumes, and it is
    what anyone building a different client consumes, so ADR-026 pt7's
    position survives as an option beside ours rather than as the design.

51. **The decider is an injection target, and that is accepted with a
    bound.** It reads every comment and every memory, and `stop`, `block` and
    `file` act on peers, so a role's prose can move the decider against
    another role. The executor bounds every verb to the declaration, and
    nothing bounds rate or source. The repository's policy file (decision 41)
    is trusted content by construction, and is named as such. Accepted rather
    than repaired: an operator confirmation on `stop` and `block` would make
    the operator the loop again, which is ADR-026's problem returning.

52. **Forgejo permissions, measured.** Forgejo 16.0.4 in docker, one
    repository, two role users added as collaborators with `read`, each
    holding a token scoped `write:issue`. Every claim the design makes about
    a role's token was probed over the API:

    | Role token can | Status |
    | --- | --- |
    | open an issue | 201 |
    | edit the body of an issue it opened | 201 |
    | comment on an issue the operator opened | 201 |
    | edit and delete its own comment | 200, 204 |
    | close and reopen an issue it opened | 201 |
    | edit or delete a peer's issue body or comment | 403 |
    | edit, close or assign on the operator's issue | 403 |
    | add a label, even to its own issue | 403 |
    | comment with a `read:issue` token | 403 |
    | write repository contents with `write:repository` | 403 |

    The operator's account, with `write`, labels freely (200) and a push to
    `refs/cageworks/record` is accepted. `GET /repos/{o}/{r}/projects` is 404:
    there is no projects API, so decision 30's columns are not something the
    executor can move.

    What this settles: decision 43's memory issue works as designed, since
    only the poster edits it; section 1's rule that a blocked actor comments
    and the executor labels is required, not optional; a role's effective
    rights are the collaborator permission and not the token scope, so
    `write:issue` on a `read` collaborator is the shape to keep; and a stage
    is a label. Comment edits keep `updated_at` at second resolution, so the
    audit of a revised comment is Forgejo's content history and not the
    timestamp. Script: a throwaway in the session scratchpad, twenty probes,
    rerunnable against any image tag.

53. **cageworks is the machine; the operator's host holds a launcher and a
    client.** Stated because nothing above said it and things grow where
    nothing forbids them. On the operator's host: `cageworks up`, `down`,
    `vm status`, `factory mirror`, the TUI (decision 49), `config.toml` with
    its ceilings and credential paths, and the origin URL read off the
    checkout. Everything else, executor, decider, Forgejo, Valkey, proxy,
    probes, the relay, lives on the machine, and a new capability is added
    there first. The TUI is the operator's one face: every operation the
    factory offers is reachable from it, and Forgejo's web UI over the
    forwarded port is available but required for nothing except the merge
    click (decision 45). If a merge verb ever lands, that exception goes too.

## 3. What this replaces in `docs/`

Fully reversed or deleted: ADR-013 (no shared database), ADR-022 (the task is a
git-bug issue), ADR-023 (leased claim), ADR-024 (claim and revalidation),
ADR-026 (the console is the loop, and now pt7's refusal to own a client),
ADR-028 (two subjects), and most of ADR-025 (uid filter, proxy uid,
resolv.conf, daemon socket) and ADR-027 (the ledger, and the probes' sink).

Amended: ADR-009 survives in substance, now stated as a role holding no
credential that can push, pull or authenticate off the machine; the
issue-scoped Forgejo token is the one credential it gains (decision 31).
ADR-010 returns to its original scope, because the widenings ADR-022 and
ADR-023 added (`refs/bugs/` and `refs/claims/` writable by every role) are both
gone, so the ref partition is clean again and `main` is writable by nobody.
ADR-016, ADR-017, ADR-019 and ADR-030 stand. ADR-015 stands except point 3,
which the decider replaces. ADR-020 loses points 3 and 3a to build-time
evaluation. ADR-029 stands and hardens. ADR-031 becomes literal rather than a
norm: a tool reaches a cage through the flake, enforced by there being no
daemon socket. ADR-032's clone-from-origin survives; its
`git remote get-url origin` off the operator's checkout does not, because the
flake input names the remote.

PRD-003's structural property returns and two of its criteria change: a bad
merge is recoverable again (decision 31), and a waiting run does hold
concurrency (decision 26). PRD-005's dispatcher non-goal is reversed
deliberately.

## 4. Owed

Two nixcage interface changes, each two commits in two repositories and a lock
bump (ADR-018): a private network per cage with a veth into the factory's
bridge, and suppressing the nix daemon socket bind. The socket is bound by
nixcage's own default and no flag of ours names it today, so the second is a
new option on `enter` rather than the removal of one. Both change the argv a
role session composes, so `tests/command/seam.bats` is where they show up as a
diff. A third change is a removal: `--subject` (ADR-028) leaves the line when
loop and agent become one uid (decision 9).

Three models before implementation. The routing one must be written so that the
board write, the send and the ack are separate actions with nothing preventing
a crash between them, which is the mistake ADR-024 documents: its predecessor's
model reported no violation because it shared the decision's own assumption
about atomicity. It must also include an actor that answers reconciliation
falsely, one that crashes, and one that stalls. Invariants: no task is
`assigned` to two actors; no `assigned` row exists that the executor did not
send; every `assigning` row resolves after reconciliation.

## 5. Accepted risks

- A hung-but-alive actor holds its task forever.
- A blocked role is spent capacity.
- Loop and agent share a uid, so anything the loop writes is as trustworthy as
  the agent, and the budget must stay at the proxy.
- The dispatcher is back, and it is now deliberately smart, so content-blind
  routing is gone. What bounds it is the executor's validation against the
  declaration.
- The record lives on the factory's pool. What was not yet mirrored to
  `refs/cageworks/record` is lost with the pool.
- A repository qualifies for a factory by being hermetic: a build that reaches
  the network does not run in a cage.
- An agent has no web access at all. The repository and its devShell are its
  only sources of fact, so `modules/role-guidance.md` carries more weight.
- The role memory is agent-written, so a wrong belief in it outlives every
  task. It is also a Forgejo issue the role may edit, so a role can revise its
  own memory's history as well as its comments.
- `main` merges by hand. A factory with no operator present stops at its
  pull requests.
- The relay is a second interface (after nixcage's three primitives) that the
  suite must assert on.
- A role's Forgejo token can edit that role's own comments, so a role can
  revise its own account after the fact.
- The decider reads untrusted prose and holds verbs that act on peers
  (decision 51). The declaration bounds what, nothing bounds how often.
- The repository's policy file is trusted content: whoever commits it steers
  the decider.
- The decider has a budget line. At its hard limit the factory stops, and the
  only signal is that nothing is assigned; the TUI has to show it.

## 6. Still open

The first session's seven questions are closed by decisions 39 to 50, and
the Forgejo questions by decision 52. What remains:

- The relay's exact JSONL shape, and where its contract test lives.
- The export format under `refs/cageworks/record`, and whether a mirrored
  record is imported back on `cageworks up` of a fresh machine.
- The `probes` stream's cap, and whether the proxy's metadata log joins the bus
  the same way or stays in journald.
- Re-announcing `ready` after a Valkey restart: the bus is unpersisted, so
  the extension must reconnect and re-announce, and the executor must treat a
  silent actor as unknown until it does.
- `cageworks up` after a rebuild (decision 15) must be idempotent for Forgejo
  accounts and tokens, memory issues and Valkey ACL users.
- Whether origin accepts a push to `refs/cageworks/record`; Forgejo does
  (decision 52), other forges are unmeasured.

## 7. Roadmap

`docs/roadmap.md`. Kept there rather than here because it is a plan of work
and outlives this file: phase 5.4 deletes the log and the roadmap stays.
