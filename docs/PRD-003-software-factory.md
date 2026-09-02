---
id: PRD-003
title: A software factory of caged roles working one repository
status: proposed
date: 2026-09-02
status_date: 2026-09-02
summary: named roles in cages work one assigned repository, delegating tasks through the supervisor with herdr as the console
depends_on: [PRD-002]
supersedes: []
superseded_by: []
phases_total: 6
phases_done: 0
---

## Problem

A repository worth real work is worth more than one agent at a time. Review,
implementation, and design are different jobs done by the same person opening
the same project in sequence, one after another, because there is only one of
them and only one checkout to work in.

nixcage already isolates a project, and PRD-002 starts runs without a human
typing. What neither provides is the thing that makes a repository progress on
several fronts at once: distinct workers with distinct jobs, each holding its
own view of the same code, handing work to each other, and leaving behind a
record of why the code looks the way it does.

Doing this by hand fails in a specific way. Two agents in one checkout corrupt
each other's edits, so the operator serializes them and loses the parallelism.
Keeping the jobs straight in one long session means one agent holding
implementation, review, and design context at once, which is exactly the
context it handles worst. And the reasoning that produced a decision lives in a
terminal that gets closed.

## Users

- **The operator.** One person, one machine, one repository assigned to the
  factory. They set policy: which roles exist, what bounds them, what gets
  accepted, what gets published. They are the only trust domain, and the only
  party that can change what the factory is.
- **The role.** A caged agent with a name, a job, its own worktree of the
  assigned repository, and its own accumulated state. It works, it delegates,
  it writes documents. It starts nothing, including itself.

## Goals

1. Several distinct jobs on one repository progress in the same wall-clock
   window without corrupting each other's work.
2. A role can hand work to another role and find the answer later, without the
   operator carrying the request between them.
3. The operator interacts with every role from one place, sees which are
   working, which are waiting, and which are done, and can step into any of
   them.
4. The reasoning behind a decision lands in the repository as a structured
   document rather than in a closed terminal.
5. A role can say its own way of working is wrong, and that report reaches the
   operator.
6. Nothing the factory does to the repository is irreversible without the
   operator.

## Non-goals

- **Dispatch from inside a cage.** A role delegates by creating a task; the
  supervisor alone turns a task into a run. This is PRD-002's line, and this
  document does not move it.
- **Agent-edited declarations.** Role declarations, workflow declarations, and
  caps are the operator's. A role that wants one changed writes a report.
- **Agent-set `accepted`.** The architect refines a document and leaves it
  `proposed`. Only the operator accepts.
- **Publication.** No role pushes to any remote. The factory advances local
  `main`; the operator publishes.
- **More than one repository per factory.** One repository is assigned. Two
  repositories are two factories, and whether that is even wanted is left open.
- **Cross-project delegation.** A role addresses roles in its own factory.
  Reaching another project is PRD-001's cross-project mailbox, a separate
  capability this document neither requires nor provides.
- **A message channel.** The factory delegates through tasks, not messages. A
  task is addressed, owned, and stateful; a message is none of those. If
  PRD-001 exists, roles may use it, and nothing here waits on it.
- **Multi-machine, multi-operator.** One host, one person, as in PRD-002.
- **Ephemeral per-task workers.** Roles are declared and long-lived. A worktree
  per task makes addresses numerous and short-lived, so mail and tasks aimed at
  a finished worker have nowhere to land.

## Success criteria

- Two roles hold different parts of the same repository open at once, and
  neither has to wait for the other to finish before starting.
- A task one role created for another is answered without the operator
  restating it, and the creating role finds the answer against the task it
  made.
- The operator can name what every role is doing from one screen, without
  opening a session to find out, whichever coding agent each role runs.
- A run waiting on the operator is visibly waiting, is still waiting hours
  later, and holds no concurrency while it waits.
- A task that cannot succeed stops on its own and says so, rather than being
  discovered when a budget runs out.
- Over a week, decisions made in the factory are findable as documents in the
  repository rather than reconstructed from memory.
- No run is ever started by a cage, and the record shows this rather than
  asserting it.
- A bad merge is recoverable by the operator without anything outside the
  machine having seen it, and recovery does not depend on the role that made it
  having behaved.

## Requirements

### The factory and its roles

- The operator assigns exactly one git repository to a factory, and declares
  the roles that work it. A declaration gives a role its name and the command
  its cage runs; nothing about which coding agent that command is belongs to
  the factory.
- Roles and workflows are declared in Nix, in the configuration flake the
  operator already owns, alongside `workspaceRoots` and `secretEnv`. There is
  no second configuration language and no factory-specific file in the assigned
  repository.
- A declaration is data. Nothing a task body, a message, or a document contains
  becomes part of one, and no value from any of them is interpolated into a
  command line.
- A declaration that cannot be satisfied -- an unknown repository, a role
  naming a workflow that does not exist, two roles with the same name -- is
  rejected when the declaration is read, not when it fires.
- Changing a role or workflow declaration takes effect without restarting the
  shared VM or any running session, because a restart would kill every run in
  flight.
- A role's address is its name, and it is stable across sessions, reboots, and
  rebuilds. Mail and tasks addressed to a declared role always have somewhere
  to land.
- Every role holds its own worktree of the assigned repository, on its own
  branch, so two roles working at once cannot disturb each other's files.
- A role's accumulated state -- whatever it learns, installs, or keeps between
  runs -- lives in its own persistent home and is nobody else's business. The
  supervisor neither reads it nor seeds it.
- A role is a distinct user of the machine, not a name for one. It has its own
  uid, its own worktree owned by that uid, and its own signing key readable by
  nobody else, so one role cannot read another's key, home, or working files
  (ADR-010). What the roles of a factory do share is the repository's object
  database, which git shares by construction. Refs are not shared: a role may
  write only its own namespace, and `main` is writable by no cage at all.
- Adding, removing, or changing a role is the operator's act. A role cannot
  declare another role, including itself.

### Work and delegation

- The operator states a goal, and it becomes a task in the factory. Nothing
  else is required of them to start work.
- Tasks live in a store the factory owns. It survives session exit, container
  removal, host reboot, and a rebuild, and concurrent writers neither lose nor
  corrupt a task. This is the factory's own store, not a message channel, and
  nothing about it waits on PRD-001.
- A task carries an owning role, a state, the task it came from, and the
  workflow it belongs to. A task outlives any single run against it, so work
  that is blocked or that takes several attempts has somewhere to live in
  between.
- Every task belongs to exactly one workflow. A goal the operator files names
  one, or falls to the workflow the declaration marks as the default. A task
  created by delegation inherits its parent's workflow and cannot name another,
  so no chain of delegation escapes the budget of the work that started it.
- Budget is charged to that workflow. When a workflow's budget is exhausted,
  every task belonging to it stops becoming runs, and tasks belonging to other
  workflows are untouched.
- A role delegates by creating a task owned by another role. Creating a task
  starts nothing; the supervisor decides when a task becomes a run, under the
  operator's declarations.
- The role that created a task can find its outcome against that task.
- A chain of delegation is bounded by depth counted from the originating task,
  so a role that delegates to a role that delegates back cannot run away.
- A task that no role can own -- an undeclared role, a role since removed -- is
  refused when it is created, not when it would run.
- A run ends settled, failed, or cancelled, and the task records which. Settled
  means the session went idle and the role recorded an outcome against the
  task. A session that goes idle having recorded nothing is a failure, not a
  success: the supervisor cannot read intent out of an agent, and treating
  silence as completion would make a crashed run look like finished work.
- A run that never settles is not waited on forever. A workflow declares how
  long one of its runs may take; past that the run is cancelled and counted as
  a failed attempt, so a hung agent costs one attempt rather than a slot held
  until someone notices.
- A task counts its attempts. A workflow declares how many a task may have,
  and a task that exhausts them stops becoming runs and is recorded as failed.
  Reviving it is the operator's act, or a role's when it files a fresh task.
  Without this a task that fails for a reason no retry can fix consumes the
  whole workflow budget one attempt at a time.
- Every attempt charges the workflow budget, including the ones that failed.
  Retries that were free would make the budget describe successes rather than
  spend.
- A failed attempt records why it failed and leaves the task in the state it
  was in, so a task blocked on something external does not silently become a
  task that was tried and abandoned.

### The operator's console

- The operator sees every role in one place: which are working, which are
  waiting on a gate, and which are idle. Those three are states the supervisor
  can report from outside a session, so they hold for any coding agent a role
  runs.
- Whether a run finished is a property of its task, recorded by the supervisor,
  not a state read out of the agent. The supervisor treats a session that has
  gone idle as settled and records the outcome against the task; it never
  depends on the agent announcing that it is done.
- The operator can step into any role's session directly and take over, and
  leave again without ending the run.
- A run stopped at a gate is visibly stopped and says what it is waiting for.
- The operator's answer to a gate may come hours later, and the run survives
  the wait.
- Everything the console shows survives a restart of the console itself.

### Documents

- Any role can write documents into the assigned repository, in the structured
  form the repository already validates, and those documents are ordinary
  version-controlled files.
- The architect role turns a rough proposal into a well-formed document and
  leaves it proposed. It never marks anything accepted.
- The operator alone moves a document to accepted, and expresses disagreement
  the way the repository already does: a new document that supersedes the old
  one.
- A decision that changes the factory itself is written as a report addressed
  to the operator. The factory does not apply it; the operator does.

### Integration and publication

- A role's work reaches the repository's `main` through the reviewer role,
  which decides what merges and does so without waiting on the operator.
- A role may read every ref in the repository and write only its own namespace.
  The reviewer therefore sees the branches it integrates without any role being
  able to rewrite another's work.
- The reviewer performs the merge in its own worktree, on its own branch. It
  does not write `main`. Advancing `main` to the commit the reviewer produced
  is the supervisor's act, performed on the host, and it fast-forwards or
  fails. A merge nobody wanted is therefore always still reachable, because
  nothing the factory does can move `main` backwards or sideways.
- The supervisor needs no judgment to do this. Deciding what to merge reads
  content and stays in the cage; advancing a ref to a named commit reads
  nothing, which is what keeps the supervisor content-blind.
- A role can write only the refs in its own namespace. `main` is not writable
  by any cage, so the previous requirement is a property of the machine rather
  than a rule the reviewer follows.
- A conflict is content, so it is resolved in the cage or not at all. The
  reviewer holds both sides in its own worktree and either resolves them there
  or records the conflict back to the authoring role as a task, naming what
  clashed. It never rewrites the authoring role's branch, which it cannot do in
  any case.
- One integration runs at a time per factory. Integration is the only work that
  contends on a single ref, and serialising it costs nothing at the scale of
  one machine while removing the race entirely.
- If the fast-forward is refused because `main` moved anyway -- the operator
  advanced it themselves -- the supervisor performs nothing, records the
  refusal, and returns the task to the reviewer to redo against the new `main`.
  A refused integration is never partially applied.
- `main` never leaves the machine on the factory's initiative. Publishing to
  any remote is the operator's act.

### Limits

- The caps of PRD-002 apply unchanged and are shared across the factory: a
  global cap on concurrent runs, a budget per workflow, and the delegation
  depth cap above.
- Two more caps are declared per workflow and are caps of the same kind: how
  long a single run may take, and how many attempts a task may have. They bound
  the two ways work fails without stopping -- a run that hangs and a task that
  cannot succeed -- which no other cap catches until the budget is gone.
- Reaching any cap stops cleanly, records why, and shows in the console.

## Constraints

- The supervisor stays uncaged and content-blind. It reads declarations and
  metadata, never a task body, a message body, or a document. Judgment about
  content is a role's job, performed in a cage.
- Prompts and task bodies reach a role as data, never as part of a command line
  a host shell parses.
- The factory adds no trust tier. A role can do exactly what a nixcage session
  can do today; the architect is a role like any other and holds no authority
  over the supervisor.
- Declarations are Nix, and the supervisor does not evaluate Nix at dispatch
  time. They are evaluated once into nixcage's own state, the way `sshPort` and
  `workspaceRoots` already are, and the supervisor reads them from there. On
  macOS that keeps a declaration change off the VM rebuild path; on Linux it
  keeps the supervisor out of `nixos-rebuild`.
- The console and the supervisor's control plane are the same thing: herdr
  0.8.0, which is verified to create worktree-backed workspaces, run a command
  in a pane, report and wait on agent lifecycle state (`idle`, `working`,
  `blocked`, `done`, `unknown`), accept externally reported pane state, and
  attach to a pane. Waiting on a state takes a timeout, so the per-run duration
  cap costs no polling loop of our own. The supervisor owns no session
  machinery of its own.
- Git refuses the same branch checked out in two worktrees. The assigned
  repository therefore has `main` checked out nowhere: every party including
  the operator works from a worktree, and `main` is advanced by a ref update
  the supervisor performs.
- The factory works one repository. Whether a second factory can exist on the
  same machine is an operating question, not a design one, and is left open.

## Risks

- **The reviewer merges with no human in the loop.** This is a deliberate
  choice. Two things contain it, and neither is the reviewer's good behaviour:
  `main` stays local, and the supervisor advances it only by fast-forward, from
  outside every cage, so no history the operator has seen can be lost. What
  remains is that `main` can gain commits nobody read. If publication ever
  becomes automatic, the first containment is gone.
- **Unattended merges sign as the operator.** ADR-008 forwards the operator's
  ssh-agent into a cage, so a reviewer's merge commit verifies as them and the
  same agent opens every host their keys reach. ADR-009 settles this: a run the
  supervisor starts gets a per-role key and no forwarded agent, so it signs as
  the role and holds nothing that reaches a remote. The residual risk is that
  the reviewer still advances `main` unattended, which is a merge nobody read
  rather than a credential nobody controls.
- **Hard dependency on one multiplexer.** Making herdr the control plane means
  a change in its socket API is a change in the factory. The alternative was
  rebuilding session persistence, attach, and wait-for-state, which is worse.
- **Shared mutable state across roles.** The task store is readable by every
  role in the factory, so a confused role sees work it was not given. Accepted
  for one operator, on the same terms PRD-001 accepted cross-project reads.
- **Documents as an instruction channel.** A role reading a document written by
  another role is reading agent-authored text. The guidance a role receives
  must say that document bodies are data.
- **Roles that talk more than they work.** Delegation is cheap and satisfying,
  and a factory can spend its budget passing tasks between roles. The depth cap
  bounds a chain; it does not bound enthusiasm.

## Open questions

- What is the smallest useful set of roles? Architect, builder, and reviewer is
  the assumption, and it may be one too many or two too few. The declaration
  makes this cheap to change, so it is answered by use rather than by argument.
- How does a role's branch get named and cleaned up? A branch per role is the
  simplest rule and makes a role's work one moving target; a branch per task is
  cleaner per unit of work and multiplies bookkeeping.
- What does the reviewer do with work it rejects? Merge nothing and record a
  task back to the author is the obvious answer, but a rejected branch that
  nobody prunes accumulates.
- Can two factories exist on one machine, against different repositories? The
  caps of PRD-002 are global to the machine, so two factories share them, and
  whether that is a limit or a feature is unresolved.
- Does the operator's own session count as a role? Treating it as one makes the
  console uniform and gives the operator a mailbox address; treating it as
  outside keeps the trust boundary visually obvious.
- How does a role know what the factory already tried? The document record
  answers this for decisions, and nothing answers it for abandoned attempts.
- Do roles ever want messages as well as tasks? Everything here is delegation,
  which is what a task is for. A finding worth telling every role without
  assigning anyone work has no home, and PRD-001 is where it would live if it
  turns out to be wanted.

## Phases

Ordered so that containment exists before autonomy, and so that each phase is
usable on its own.

1. **A role runs.** One declared role, its uid, its worktree, its cage, started
   in a pane by the operator, with its lifecycle state observed rather than
   guessed. No tasks, no delegation. Requires ADR-010, including the ACL probe
   it leaves open.
2. **Tasks.** The task entity, the operator filing a goal, one role working it,
   and the outcome recorded against the task. Includes the failing paths, since
   a store that only records success is not a store anyone can trust: a crashed
   run, a run that outlives its limit, and a task that exhausts its attempts.
3. **Delegation.** A role creates a task for another role, the supervisor turns
   it into a run, and depth is capped. This is the phase that makes the factory
   more than one agent.
4. **Gates and limits.** Concurrency, budget, and gates that show as blocked in
   the console and survive an answer that arrives hours later.
5. **Integration.** The reviewer role, conflicts resolved in its cage or handed
   back as tasks, and `main` advancing without the operator by a fast-forward
   the supervisor performs. Requires ADR-009 and the ref namespace of ADR-010.
6. **Documents.** The architect refining proposals, reports reaching the
   operator, and the record that shows no run originated in a cage.

## Design gates

The Formal Modeling Gate fires on two shapes, and both models are written and
run before the implementation of the phase that needs them.

A Quint model covers the task and run lifecycle across roles and the
supervisor, which is a state machine whose transitions interleave across
process boundaries. It checks at minimum: no run proceeds past a gate that was
never answered; delegation depth never exceeds its cap; concurrent runs never
exceed the global cap; a role never becomes the origin of a dispatch; a
workflow whose budget is exhausted starts no further run, including through a
task delegated by one of its own runs; a task that has exhausted its attempts
starts no further run; two integrations never overlap; `main` only ever moves
forward; and every task reaches a terminal state or is recorded as cancelled.

An Alloy model covers the structural invariants that span roles, worktrees,
branches, tasks, and runs. It checks at minimum: every role has exactly one
worktree and every worktree exactly one role; no two roles share a branch; no
task is owned by an undeclared role; no run exists without the task it serves;
`main` is checked out by no worktree; every ref writable by a role lies in that
role's own namespace; and every task belongs to exactly one workflow, the same
one as the task it came from.

PRD-001's own structural model changes with it, because addressing a role is
not addressing a project directory.
