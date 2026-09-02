---
id: PRD-003
title: A software factory of caged roles working one repository
status: proposed
date: 2026-09-02
status_date: 2026-09-02
summary: named roles in cages work one assigned repository, delegating tasks through the supervisor with herdr as the console
depends_on: [PRD-001, PRD-002]
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

nixcage already isolates a project. PRD-001 lets containers exchange messages.
PRD-002 starts runs without a human typing. What none of them provides is the
thing that makes a repository progress on several fronts at once: distinct
workers with distinct jobs, each holding its own view of the same code, handing
work to each other, and leaving behind a record of why the code looks the way
it does.

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
- **Cross-project delegation.** A role addresses roles in its own factory. The
  cross-project mailbox of PRD-001 is a different capability and stays where it
  is.
- **Multi-machine, multi-operator.** One host, one person, as in PRD-001 and
  PRD-002.
- **Ephemeral per-task workers.** Roles are declared and long-lived. A worktree
  per task makes addresses numerous and short-lived, which PRD-001 already
  named as a failure of the mailbox.

## Success criteria

- Two roles hold different parts of the same repository open at once, and
  neither has to wait for the other to finish before starting.
- A task one role created for another is answered without the operator
  restating it, and the creating role finds the answer against the task it
  made.
- The operator can name what every role is doing from one screen, without
  opening a session to find out.
- A run waiting on the operator is visibly waiting, is still waiting hours
  later, and holds no concurrency while it waits.
- Over a week, decisions made in the factory are findable as documents in the
  repository rather than reconstructed from memory.
- No run is ever started by a cage, and the record shows this rather than
  asserting it.
- A bad merge is recoverable by the operator without anything outside the
  machine having seen it.

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
- Adding, removing, or changing a role is the operator's act. A role cannot
  declare another role, including itself.

### Work and delegation

- The operator states a goal, and it becomes a task in the factory. Nothing
  else is required of them to start work.
- A task carries an owning role, a state, and a link to the task it came from.
  A task outlives any single run against it, so work that is blocked or that
  takes several attempts has somewhere to live in between.
- A role delegates by creating a task owned by another role. Creating a task
  starts nothing; the supervisor decides when a task becomes a run, under the
  operator's declarations.
- The role that created a task can find its outcome against that task.
- A chain of delegation is bounded by depth counted from the originating task,
  so a role that delegates to a role that delegates back cannot run away.
- A task that no role can own -- an undeclared role, a role since removed -- is
  refused when it is created, not when it would run.

### The operator's console

- The operator sees every role in one place: which are working, which are
  waiting, which are idle, and which are done.
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
  which merges without waiting on the operator.
- `main` never leaves the machine on the factory's initiative. Publishing to
  any remote is the operator's act.
- A merge preserves history, so an unwanted merge is recoverable by the
  operator.

### Limits

- The caps of PRD-002 apply unchanged and are shared across the factory: a
  global cap on concurrent runs, a budget per workflow, and the delegation
  depth cap above.
- Reaching a cap stops cleanly, records why, and shows in the console.

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
  attach to a pane. The supervisor owns no session machinery of its own.
- Git refuses the same branch checked out in two worktrees. The assigned
  repository therefore has `main` checked out nowhere: every party including
  the operator works from a worktree, and the reviewer advances `main` by
  updating the ref.
- The factory works one repository. Whether a second factory can exist on the
  same machine is an operating question, not a design one, and is left open.

## Risks

- **The reviewer merges with no human in the loop.** This is a deliberate
  choice, and its containment is that `main` stays local and history is
  preserved, so the operator can reset. If publication ever becomes automatic,
  the containment is gone.
- **Unattended merges sign as the operator.** ADR-008 forwards the operator's
  ssh-agent into a cage, so a reviewer's merge commit verifies as them and the
  same agent opens every host their keys reach. PRD-002 raised a cage-only
  signing key as an open question; with an autonomous reviewer it stops being
  optional. This document does not decide it, and names it as the thing to
  decide before phase 5.
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

## Phases

Ordered so that containment exists before autonomy, and so that each phase is
usable on its own.

1. **A role runs.** One declared role, its worktree, its cage, started in a
   pane by the operator, with its lifecycle state observed rather than guessed.
   No tasks, no delegation.
2. **Tasks.** The task entity, the operator filing a goal, one role working it,
   and the outcome recorded against the task.
3. **Delegation.** A role creates a task for another role, the supervisor turns
   it into a run, and depth is capped. This is the phase that makes the factory
   more than one agent.
4. **Gates and limits.** Concurrency, budget, and gates that show as blocked in
   the console and survive an answer that arrives hours later.
5. **Integration.** The reviewer role, and `main` advancing without the
   operator. Requires the signing question above to be decided first.
6. **Documents.** The architect refining proposals, reports reaching the
   operator, and the record that shows no run originated in a cage.

## Design gates

The Formal Modeling Gate fires on two shapes, and both models are written and
run before the implementation of the phase that needs them.

A Quint model covers the task and run lifecycle across roles and the
supervisor, which is a state machine whose transitions interleave across
process boundaries. It checks at minimum: no run proceeds past a gate that was
never answered; delegation depth never exceeds its cap; concurrent runs never
exceed the global cap; a role never becomes the origin of a dispatch; and every
task reaches a terminal state or is recorded as cancelled.

An Alloy model covers the structural invariants that span roles, worktrees,
branches, tasks, and runs. It checks at minimum: every role has exactly one
worktree and every worktree exactly one role; no two roles share a branch; no
task is owned by an undeclared role; no run exists without the task it serves;
and `main` is checked out by no worktree.

PRD-001's own structural model changes with it, because addressing a role is
not addressing a project directory.
