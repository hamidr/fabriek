---
id: PRD-003
title: A software factory of caged roles working one repository
status: implementing
date: 2026-09-02
status_date: 2026-09-03
summary: named roles in cages work one assigned repository, delegating tasks through the supervisor with herdr as the console
depends_on: [PRD-002]
supersedes: []
superseded_by: []
phases_total: 7
phases_done: 4
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
- **A scheduler.** A workflow is triggered by the operator and by nothing else.
  No timer starts work, which keeps the unattended surface exactly as wide as
  the operator made it that day. PRD-002's open question about schedule
  triggers stays open there and is answered no here.
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
- No run is ever started by a cage. This is structural rather than observed:
  no cage holds the CLI that starts runs, so the property is a fact about what
  is in a cage. What the record shows is the weaker and still useful thing,
  that every run has a workflow, a task, and a reason.
- A bad merge is recoverable by the operator without anything outside the
  machine having seen it, and recovery does not depend on the role that made it
  having behaved.

The criteria above say the factory works. These say whether it is worth
keeping, and they are answerable from the run record and from git alone:

- Over a month, a real share of the commits reaching `main` arrive on role
  branches rather than from the operator's own. A factory that works but
  produces nothing is a costume.
- The operator's interventions per merged task -- gates answered, tasks
  revived, conflicts handed back -- fall over time rather than holding steady.
  If they hold steady the operator is still doing the work, through a slower
  interface.
- The share of integrations the operator later reverts or supersedes stays low
  enough that reviewing after the fact is cheaper than reviewing before it. If
  it does not, the reviewer merging freely was the wrong call and the gate
  belongs before integration.
- Budget spent per task that reached `main` is known, so the factory can be
  compared against the operator doing the same work, rather than assumed to be
  cheaper.

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
- Every role holds one worktree of the factory's clone, permanently. It is not
  created or destroyed per task, so two roles working at once cannot disturb
  each other's files and nothing is re-owned between units of work.
- A role checks out a fresh branch in that worktree for each task it takes,
  named for the task inside the role's own namespace. A task awaiting review
  then names something that stops changing, so the reviewer integrates that
  task's work and nothing that landed after it. The branch is deleted when its
  task reaches `done` and kept when the task `failed`, because a failed task's
  branch is the evidence of what went wrong.
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
- A workflow is a pipeline. It declares its stages in order, which role owns
  each, where a stage fans out into several tasks, and where a gate sits. What
  the factory can do is therefore readable from the declaration rather than
  emergent from what a role decides at the time.
- A task carries an owning role, a state, the task it came from, the workflow
  it belongs to, and the stage it sits at. A task outlives any single run
  against it, so work that is blocked or that takes several attempts has
  somewhere to live in between.
- A task has exactly these states: `proposed` when filed but not yet runnable,
  `ready` when it may run, `running` while a run is active against it,
  `blocked` while it waits on another task, `awaiting-review` when its work is
  done and the reviewer has not integrated it, and the terminal `done`,
  `failed`, and `cancelled`.
- A run has its own states, because a task outlives its runs and the two
  answer different questions: `starting`, `working`, `gated` while stopped at a
  gate, and the terminal `settled`, `failed`, and `cancelled`. A task
  `blocked` means the backlog is stalled; a run `gated` means the operator is
  the bottleneck, and conflating them would hide which.
- A task becomes `ready` when it carries the fields its workflow declares
  required, an owner and acceptance criteria at minimum. The supervisor checks
  they are present and non-empty and nothing more, which is a metadata check
  and judges no content. A task with no stated finish line would otherwise
  spend all its attempts discovering it cannot be done.
- Every task belongs to exactly one workflow. A goal the operator files names
  one, or falls to the workflow the declaration marks as the default. A task
  created by a stage inherits its parent's workflow and cannot name another, so
  no cascade escapes the budget of the work that started it.
- Budget is charged to that workflow, in runs and, where the agent reports it,
  in tokens. Runs are always enforced because they are observable from outside
  a cage whatever agent a role runs; a token figure additionally bounds a
  workflow when reported. A reported figure reaches the supervisor as a number
  and is validated as one, so the supervisor still parses no agent prose.
- When a workflow's budget is exhausted by either measure, every task belonging
  to it stops becoming runs, and tasks belonging to other workflows are
  untouched.
- A role's session starts once and stays live. A task admitted to that role is
  handed to the session it already has, so a role carries what it learned into
  the next task instead of rediscovering the repository each time. A run is
  therefore a turn in a session rather than a process, and the caps bound a
  turn: concurrency, budget, attempts, and the duration limit are unchanged in
  meaning. A session is restarted when a turn fails, or when the operator says
  so, which is what stops a session that has talked itself into something wrong
  from carrying that into every later task.
- A role with no work has a live session and no turn in progress. It holds no
  concurrency, because concurrency counts turns and not sessions.
- A role advances work by creating the tasks its stage's outgoing edges allow,
  and cannot address a role the pipeline does not connect it to. Creating a
  task starts nothing; the supervisor decides when a task becomes a run.
- Among the tasks ready for one role, the oldest runs first. There is no
  priority: ordering a backlog by hand is a job the operator would end up
  doing, and the way to change what runs next is to cancel what should not.
- A role runs one task at a time. Its worktree holds one branch, and git allows
  no more, so this is a property rather than a declared limit. Work that must
  happen in parallel is declared as several roles, each with its own worktree
  and uid.
- The role that created a task can find its outcome against that task.
- A role may also ask another role for something it needs before it can
  continue. Who may ask whom is declared as a second graph beside the stages,
  and unlike the pipeline it may point backwards, because the role that can
  answer a question is usually the one that came before. Asking creates a
  consult task owned by the answering role, and the asking task becomes
  `blocked` until the consult reaches a terminal state.
- A consult task creates nothing at all: no consult of its own, and no pipeline
  work either. It answers and ends. That, rather than acyclicity, is what makes
  waiting safe: every consult is a leaf, so no chain of roles waiting on each
  other can close into a loop no matter what the declared graph allows.
- A blocked task keeps its role. Nothing is committed and no branch is
  switched, so a role's worktree always holds exactly the task it is working
  and the role takes no other work until the consult resolves. The cost is idle
  time rather than a new way to fail, and idle time is measurable: if roles are
  seen waiting, freeing them becomes a change made on evidence.
- A task that stops being blocked is readmitted rather than resumed, for the
  same reason an answered gate is: it released its concurrency slot while it
  waited, and the slot may be gone. It never released its role.
- A pipeline is acyclic, and every stage is reachable from the entry stage. A
  declaration that fails either is rejected when it is read: a cycle would let
  work run away, and a stage nothing reaches is dead declaration that a consult
  could nonetheless drop a task onto.
- Depth along the pipeline is then bounded by the number of stages rather than
  by a counter the supervisor keeps at run time. Consults sit outside that
  bound on purpose, since asking backwards revisits a stage by definition, and
  they are bounded instead by being leaves.
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

### The shared record

- The factory keeps a record that roles and the operator both read and write:
  what a task is for, what a role concluded, what someone asked, and what
  happened. A task cannot carry it, because a task has one owner and a
  lifecycle and a discussion has neither.
- The record lives in the repository the factory works and travels with it, so
  reading it needs nothing but the repository and the operator can read it on
  their own machine with their own tools (ADR-013).
- Every entry is attributed to whoever wrote it, and entries are never edited
  or removed. A record that can be rewritten is not worth reading back.
- A role's own writing reaches the record when its turn ends. A role cannot
  reach the record directly; it writes what it wants recorded and the
  supervisor puts it there, which is the same path an outcome already takes.
  Two roles therefore cannot converse inside one turn: this is a record that
  accumulates rather than a conversation held live.
- The supervisor writes what it did as it does it -- an attempt started, no
  outcome recorded, work settled and moved on -- into the same record, so
  reading one item top to bottom is the story of that work.
- Everything a role should read is put in front of it when its turn begins,
  marked as new since it last ran. The supervisor keeps what each role has
  already seen; nothing asks a role to remember.

### Asking for someone's attention

- A role can mark an item for another role in its workflow. The mark is
  metadata, never prose: the supervisor acts on it without reading anything an
  agent wrote, which is the same rule that keeps a task body out of a command
  line.
- A mark does not start anything. The marked role finds it when it next runs,
  and if it has no other work it does not run, so the mark waits. This is a
  real limitation rather than an oversight, and the guidance a role receives
  has to say so or roles will assume otherwise.
- Turning a mark into work is what a consult does, and a consult is a task.
  There is no third mechanism: anything that must cause a run is a task,
  because a task is what becomes one.

### The operator's console

- The operator sees every role in one place: which are working, which are
  waiting on a gate, and which are idle. Those three are run states the
  supervisor can report from outside a session, so they hold for any coding
  agent a role runs.
- Whether a run finished is a property of its task, not a state read out of the
  agent. A turn ends when an outcome is recorded against the task, which works
  whatever agent a role runs; a pane going idle is a hint the supervisor may use
  where herdr recognises the agent, never the thing it depends on.
- The operator can step into any role's session directly and take over, and
  leave again without ending the run.
- A run stopped at a gate is visibly stopped and says what it is waiting for.
- The operator's answer to a gate may come hours later, and the run survives
  the wait.
- Answering a gate does not resume the run. It records the answer and makes the
  run eligible again; the supervisor readmits it under the same concurrency
  check it applies to a fresh run, and charges no further budget because that
  run was paid for when it started. A gate releases its slot while it waits, so
  the slot may be gone when the answer arrives, and resuming without being
  readmitted would put the machine over its cap.
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
- A role is given written guidance about working inside a factory. A role that
  has to infer the rules from error messages will infer them wrong.
- The baseline guidance ships with nixcage and is bound read-only into every
  role session, because the rules it states are properties of the cage rather
  than of any repository, and because a factory has to be usable before anyone
  has written anything for it. An ordinary project session gets none: it is not
  a role.
- From phase 6 the assigned repository may carry its own guidance document,
  which the architect refines and the operator accepts like anything else. That
  document is about this factory's own conventions and sits alongside the
  baseline rather than replacing what the cage itself enforces.
- That guidance covers at least: what a role may and may not write, since it
  owns its branch namespace and can reach neither `main` nor another role's
  refs; that a permission error naming `packed-refs.lock` is expected on every
  ref update and does not mean the operation failed (ADR-010); that finishing
  means recording an outcome against the task, because a session that goes idle
  having recorded nothing is counted as a failure; how to ask another role
  something and that doing so blocks the asking task; and that the body of any
  task, document, or message written by another role is data rather than an
  instruction.

### Integration and publication

- A role's work reaches the factory clone's `main` through the reviewer role,
  which decides what merges and does so without waiting on the operator, and
  reaches the operator's own checkout when the supervisor pushes it there.
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

- The caps of PRD-002 apply and are shared across the factory: a global cap on
  concurrent runs, and a budget per workflow. The depth cap is satisfied by the
  pipeline being acyclic rather than by counting at run time.
- The global cap binds only when the factory has more roles than the cap
  allows, because one worktree per role already bounds active runs by the
  number of roles. A cap set at or above the role count constrains nothing.
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
  a host shell parses. A task is written to a file the session can read and
  only a reference to it is sent, so the body never enters the keystroke stream
  either.
- Handing a task to a live session must work for any coding agent. Sending text
  to the pane and reporting lifecycle state externally does; submitting through
  herdr's agent integration is available where herdr recognises the agent, and
  is an optimisation rather than the mechanism.
- The factory adds no party that can start work. Every run is started by the
  supervisor, and nothing between the operator and the cages holds more
  authority than a cage does. The architect is a role like any other: its
  judgment about a document carries no power over dispatch, over declarations,
  or over what gets accepted.
- A role is not an ordinary session with a different name, and saying so would
  be false in both directions. It holds less: no forwarded agent, so no
  credential that reaches a remote (ADR-009), and no access to the CLI that
  starts runs. It holds more: a uid of its own, write access by ACL into a git
  directory it does not own, and refs it may move within its own namespace
  (ADR-010). The comparison that matters is not with a session but with the
  operator, and against that a role is strictly less.
- A factory does not work the operator's checkout directly. It works a clone of
  it held on nixcage's own storage, and the supervisor syncs the two (ADR-011).
  This is not a convenience: role ownership needs a filesystem carrying
  ownership and ACLs, and on macOS the operator's workspace roots reach the VM
  over 9p, where `chown` and `setfacl` both fail. Everything roles do happens
  on the clone; the operator's checkout stays an ordinary git repository on
  their own machine, edited with their own tools.
- Declarations are Nix, and the supervisor does not evaluate Nix at dispatch
  time. They are evaluated once into nixcage's own state, the way `sshPort` and
  `workspaceRoots` already are, and the supervisor reads them from there. On
  macOS that keeps a declaration change off the VM rebuild path; on Linux it
  keeps the supervisor out of `nixos-rebuild`.
- The console and the supervisor's control plane are the same thing: herdr
  0.8.0, which is verified to create worktree-backed workspaces, run a command
  in a pane, report and wait on agent lifecycle state (`idle`, `working`,
  `blocked`, `unknown`), and attach to a pane. Creating an unfocused workspace,
  running a command in its pane, reading pane state, reporting state from
  outside, and closing the workspace again were all measured against 0.8.0.

  Three caveats came out of measuring rather than reading. Reporting state must
  go to the socket as `pane.report_agent`: the `herdr pane report-agent`
  command refuses its own required `--source` flag and cannot be used. `herdr
  agent wait` does not observe reported state, neither an existing one nor a
  transition made while it waits, so waiting on a pane only works for an agent
  herdr detects itself; a role's turn therefore ends when its outcome is
  recorded, not when a pane goes idle, and pane state is what makes a role
  visible rather than what makes it observable.

  The third is a containment matter. `herdr pane run` types its words into the
  pane's shell rather than executing them: quoting is not preserved, a literal
  `--` arrives as a word, and whatever is sent is re-split by that shell. Only
  fixed, already-validated words may go through it. Nothing carrying a task
  body, a message, or any other agent-authored text ever can, which is the
  same rule that keeps a prompt out of a command line, applied to keystrokes. Waiting on a state takes a timeout, so the per-run duration
  cap costs no polling loop of our own. The supervisor owns no session
  machinery of its own.
- Git refuses the same branch checked out in two worktrees, so `main` is
  checked out by nothing and exists only as a ref. That is what makes advancing
  it a ref update the supervisor can perform rather than a merge someone has to
  hold a working tree for.
- The factory clone keeps a primary working tree, since a cage needs a
  `flake.nix` at `/workspace`, and that tree is the supervisor's rather than
  anyone's to edit. It sits on a branch that is not `main`, so `main` is
  checked out by nothing there either.
- Ownership follows from that. The clone and its common `.git` belong to the
  supervisor. A role owns its worktree and its `.git/worktrees/<role>` entry,
  and reaches the rest by ACL: the object database, and its own
  `refs/heads/<role>/` and reflog directory (ADR-010).
- The clone and every role worktree live in nixcage's own state, not under a
  workspace root. They are the supervisor's to create and remove, and putting
  them beside the operator's projects would make them enterable by hand as if
  they were projects of their own.
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
- What does the supervisor do when the operator's checkout and the factory
  clone have diverged, because the operator rewrote history in their own
  repository? Reconciling is not the same as fetching, and nothing says which
  side wins or whether a role's branch survives it.
- When do consults land? A role can mark work for another role, and that mark
  waits until the marked role runs for some other reason. Turning a mark into a
  run is a consult, which is a task, and it was deliberately deferred out of
  the delegation phase rather than dropped. Until it exists, a question asked of
  an idle role is a question that waits.
- Do roles ever want messages as well as tasks? Delegation is what a task is
  for, and the shared record now carries discussion about work that exists. A
  finding worth telling every role without assigning anyone work still has no
  home, and PRD-001 is where it would live if it turns out to be wanted.

## Phases

Ordered so that containment exists before autonomy, and so that each phase is
usable on its own.

1. **A role runs.** One declared role, its uid, its worktree, its cage, started
   in a pane by the operator, with its lifecycle state observed rather than
   guessed. No tasks, no delegation. Carries the first slice of role guidance,
   because a role hitting the expected `packed-refs.lock` error with nothing
   telling it that is expected will report a failure that did not happen.
2. **Tasks.** The task entity, the operator filing a goal, one role working it,
   and the outcome recorded against the task. Includes the failing paths, since
   a store that only records success is not a store anyone can trust: a crashed
   run, a run that outlives its limit, and a task that exhausts its attempts.
3. **Delegation.** The pipeline: a role creates work along the stage edges its
   declaration allows, a stage fans out into several tasks, and the supervisor
   turns each into a run. Nothing counts depth at run time, because the
   declaration is checked for cycles and for unreachable stages when it is
   read. This is the phase that makes the factory more than one agent, and the
   phase where fan-out first shows that parallelism is a property of how many
   roles are declared rather than of how many tasks exist.
4. **The record.** The shared record roles and the operator write into,
   attention marks that arrive with a role's next turn, and the supervisor
   narrating what it did. Sequenced before the caps because it adds no autonomy
   -- it changes what a role knows, not what it may do -- and because it is the
   first thing that makes a role's turn depend on what another role wrote.
5. **Gates and limits.** Concurrency, budget, and gates that show as blocked in
   the console and survive an answer that arrives hours later.
6. **Integration.** The reviewer role, conflicts resolved in its cage or handed
   back as tasks, and `main` advancing without the operator by a fast-forward
   the supervisor performs. Requires ADR-009 and the ref namespace of ADR-010.
7. **Documents.** The architect refining proposals, the guidance becoming a
   document the architect maintains rather than a fixed string, and reports
   reaching the operator.

## Design gates

The Formal Modeling Gate fires on two shapes. Both models are written and run,
and both live under `models/`.

`models/factory-lifecycle.qnt` covers the task and run lifecycle across roles
and the supervisor, which is a state machine whose transitions interleave
across process boundaries. It checks: no run proceeds past a gate that was
never answered; delegation depth never exceeds its cap; concurrent runs never
exceed the global cap; a role never becomes the origin of a dispatch; a
workflow whose budget is exhausted starts no further run, including through a
task one of its own runs created; a task that has exhausted its attempts starts
no further run; a role never runs two tasks at once; two integrations never
overlap; a run whose gate was answered and a task that stopped being blocked
are both readmitted under the concurrency cap rather than resuming through it;
no consult task creates any task at all, so no set of tasks can wait on each
other in a cycle; `main` only ever moves forward; and every task reaches a
terminal state or is recorded as cancelled.

`models/factory-structure.als` covers the structural invariants that span
roles, worktrees, branches, tasks, and runs. Its facts state only what the
mechanism gives, so each claim below has to follow from them rather than be
restated. It checks: every role has exactly one
worktree and every worktree exactly one role; no two roles share a branch; no
task is owned by an undeclared role; no run exists without the task it serves;
`main` is checked out by no worktree; every ref writable by a role lies in that
role's own namespace; every task belongs to exactly one workflow, the same one
as the task it came from; every task sits at a stage its workflow declares;
every task a stage creates is owned by a role that stage has an edge to; no
pipeline contains a cycle; every consult task is owned by a role the asking
stage is declared to consult; no consult task has a task of its own; every
stage is reachable from its workflow's entry stage; and the no-revisited-stage
bound holds along pipeline edges, which is where it is claimed.

PRD-001's own structural model changes with it, because addressing a role is
not addressing a project directory.

The models found three things before any code existed.

The structural model rejected two claims as written. "A cascade never revisits
a stage" is false once a consult may point backwards, so that bound is stated
over pipeline edges and consults are bounded by being leaves instead. And a
workflow could declare a stage unreachable from its entry that a consult could
still drop a task onto, so reachability became a rule the declaration is
checked against when it is read.

The lifecycle model found one defect. A gate releases
its concurrency slot while it waits, and the design said nothing about the way
back, so a run whose gate was answered resumed straight into working and put
the machine over its cap: with a cap of two, one run at a gate, two more
started while the operator was away, and the answer arriving made three. The
requirement that an answered gate is readmitted rather than resumed exists
because of that counterexample, and a task that stops being blocked is
readmitted for the same reason: it released a slot while it waited, and the
slot may be gone. That second trace needed 200000 samples at 70 steps to
surface, having been missed entirely at 20000.
