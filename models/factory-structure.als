/*
 * Structural invariants of the software factory in
 * docs/PRD-003-software-factory.md, under the ownership and ref rules of
 * docs/ADR-010-role-cage-identity.md, as widened by
 * docs/ADR-022-the-task-is-a-git-bug-issue.md and
 * docs/ADR-023-a-leased-claim-takes-a-task.md, and widened again by
 * docs/ADR-027-observed-from-three-sources.md, which gives every role a
 * ledger and a transcript beside its worktree.
 *
 * Agents now write the record themselves and race each other for claims, so
 * two ref spaces are writable by every role. ADR-010's partition still holds
 * over branches, and this model is where that boundary is stated: any ref two
 * roles can both write is one of the shared ones, and nothing else.
 *
 * The facts state only what the mechanism gives: one uid and one worktree per
 * role, an ACL that makes a ref writable exactly by the role whose namespace
 * holds it, git requiring write access to the branch a worktree has checked
 * out, and the local rule for where a task may be created. Everything the
 * documents *claim* is an assertion, so a claim that does not follow from the
 * mechanism shows up as SAT.
 *
 * Every command runs at scope 6 but 18 Path. A role now holds three paths, so
 * six of them is two roles' worth and NonTrivialFactory, which wants three
 * roles, went UNSAT the moment the ledger arrived. A witness that stops being
 * reachable because the scope ran out is a scope bug reported as a design one.
 */

sig Uid {}

-- ADR-027: a place on the machine, and whose it is. Introduced because a role
-- now owns three of them and the difference between them is the whole of
-- points 3 and 4: what a role commits from, what records what it did, and what
-- records what it saw.
sig Path { pathOwner: one Uid }

sig Worktree { owner: one Uid, checkedOut: one Ref, at: one Path }

-- ADR-027 point 4: an entry carries the uid journald read off SO_PEERCRED, and
-- not one the writer supplied. A role can write a line that lies about what it
-- did; it cannot write one that lies about who it is.
sig Entry { writer: one Role, stamped: one Uid }

-- ADR-010: a ref lives in at most one role's namespace. refs/heads/main lives
-- in none, which is the whole mechanism behind "main is writable by no cage".
sig Ref { namespace: lone Role }
one sig Main extends Ref {}

-- ADR-022 and ADR-023: refs/bugs and refs/claims carry an ACL for every role
-- uid rather than for one, because an agent writes its own record entries and
-- takes its own work. They are in nobody's namespace: they are reached by an
-- ACL over the directory, which is a different mechanism from the partition.
abstract sig Shared extends Ref {}
sig RecordRef extends Shared {}
sig ClaimRef extends Shared {}

-- ADR-023: a claim is a ref, one per task at most. How a claim is taken, held
-- and lost over time is models/task-claim.qnt; what is structural is that it
-- names a role capable of the work and lives in the shared claim space.
sig Claim { task: one Task, holder: one Role, ref: one ClaimRef }

-- ADR-015: what a role can do, declared. A stage names one of these rather
-- than naming a role, so a column in the flow and a worker are different
-- objects.
sig Capability {}

-- ADR-027 point 3: one stream splits into a ledger of metadata and a
-- transcript of content, on two paths, because only the ledger is read by
-- anything of ours and the decision to read the other should always be a
-- deliberate one.
sig Role {
  uid: one Uid,
  tree: one Worktree,
  ledger: one Path,
  transcript: one Path,
  provides: set Capability
}

-- ADR-027 point 12: the supervisor is given no reader for the ledger and none
-- for the transcript either. It is here so that content-blindness is a
-- property of what it holds rather than of what it chooses to open.
one sig Supervisor { reads: set Path }

sig Workflow { stages: set Stage, entry: one Stage }
-- next: pipeline edges, acyclic. consults: who this stage may ask, and it may
-- point backwards, so this relation is deliberately not required acyclic.
sig Stage { needs: one Capability, next: set Stage, consults: set Role }

sig Task {
  workflow: one Workflow,
  stage: one Stage,
  parent: lone Task,
  state: one TaskState,
  kind: one TaskKind
}

-- ADR-015 decision 4: a task sticks to the role that took it, and every later
-- attempt goes to that role. Attempts are modelled because stickiness is a
-- claim about several of them; with a single taker field it would be true by
-- construction and say nothing.
sig Attempt { task: one Task, by: one Role, branch: one Ref }
abstract sig TaskKind {}
one sig Pipelined, Consult extends TaskKind {}
abstract sig TaskState {}
one sig Proposed, Ready, Running, Blocked, AwaitingReview, Done, Failed, Cancelled
  extends TaskState {}

/* ---------- the mechanism ---------- */

-- Everything a role's uid can write: its own branch namespace, plus the two
-- shared spaces every role can write.
fun writable[r: Role]: set Ref { namespace.r + Shared }

-- The branches a role owns. This is what the ADR-010 partition is about, and
-- what a worktree and an attempt are restricted to.
fun branches[r: Role]: set Ref { namespace.r }

-- The roles that may take a stage's work: those providing what it needs.
fun capable[s: Stage]: set Role { provides.(s.needs) }

-- ADR-010 decision 1 and 6: a uid per role, a worktree per role, owned by it.
fact RoleIdentity {
  all disj a, b: Role | a.uid != b.uid
  all disj a, b: Role | a.tree != b.tree
  all r: Role | r.tree.owner = r.uid
  all w: Worktree | some r: Role | r.tree = w
}

-- ADR-027 point 4: journald reads SO_PEERCRED off its own socket. The uid on
-- an entry is the writer's, whatever the entry says about itself.
fact JournaldStampsThePeer {
  all e: Entry | e.stamped = e.writer.uid
}

-- ADR-027 points 3 and 8: three paths per role, none of them the same as
-- another role's and none of them the same as each other. The ledger and the
-- transcript sit under the state directory rather than in the tree the role
-- commits from.
fact ARolesPathsAreItsOwn {
  all r: Role | r.tree.at != r.ledger and r.tree.at != r.transcript
  all r: Role | r.ledger != r.transcript
  all disj a, b: Role |
    no (a.tree.at + a.ledger + a.transcript) & (b.tree.at + b.ledger + b.transcript)
  all p: Path | some r: Role | p in (r.tree.at + r.ledger + r.transcript)
}

-- ADR-027 point 4: nothing writes the ledger as a plain file under a role's
-- uid, which would be a record a role could edit. journald owns it, and
-- journald is not any role.
fact TheLedgerIsNotARolesToOwn {
  all r: Role | r.ledger.pathOwner not in Role.uid
}

-- ADR-010: a role's worktree is the role's, which is what the ACLs are for.
fact AWorktreeIsItsRolesToOwn {
  all r: Role | r.tree.at.pathOwner = r.uid
}

-- ADR-027 point 12: what the supervisor was handed, and it was handed no
-- reader at all.
fact TheSupervisorIsGivenNoReader {
  no Supervisor.reads
}

-- ADR-010 decision 5: Main is in nobody's namespace.
fact MainHasNoNamespace { no Main.namespace }

-- A shared ref is not in anybody's namespace either, so it is not a branch and
-- cannot be checked out or committed to as one.
fact SharedRefsAreNotNamespaced { no Shared.namespace }

-- git: a worktree can only be worked in if its role can write the branch it
-- has checked out. This is a fact about git, not a choice of ours.
fact CommitNeedsAWritableBranch {
  all r: Role | r.tree.checkedOut in branches[r]
}

-- ADR-015: a stage no declared role can work is rejected when the declaration
-- is read, exactly as a stage naming an undeclared role was.
fact EveryStageIsCoverable {
  all s: Stage | some capable[s]
}

-- ADR-023 decision 7 keeps ADR-015's rule that taking resolves a capability.
-- What it does NOT keep is the recorded taker answering for every later
-- attempt: a lease any capable agent may reclaim ends that, so there is no
-- fact here forcing two attempts at one task to share a role.
fact TakingResolvesACapability {
  all a: Attempt | a.by in capable[a.task.stage]
}

-- ADR-010, and ADR-023 decision 6: an attempt works a branch in its OWN
-- taker's namespace. An agent taking over an expired claim therefore branches
-- afresh rather than continuing a branch it cannot write.
fact AttemptsWorkTheirTakersBranch {
  all a: Attempt | a.branch in branches[a.by]
}

-- ADR-023: a claim belongs to one task and one ref, and is held by a role that
-- can actually do the work.
fact ClaimShape {
  all disj c, d: Claim | c.task != d.task
  all disj c, d: Claim | c.ref != d.ref
  all c: Claim | c.holder in capable[c.task.stage]
}

-- PRD-003: a pipeline's stages belong to it, its edges stay inside it, and it
-- is acyclic because a cyclic declaration is rejected when read.
fact PipelineShape {
  all w: Workflow | w.entry in w.stages
  all w: Workflow | w.stages.next in w.stages
  -- every stage is reachable from the entry stage: a stage nothing can reach
  -- is dead declaration, and is rejected when the declaration is read.
  all w: Workflow | w.stages in w.entry.*next
  all s: Stage | s not in s.^next
  all s: Stage | one w: Workflow | s in w.stages
}

-- PRD-003: the local rule for creating work. A root task sits at the entry
-- stage; a created task inherits the workflow and sits at a stage its parent's
-- stage has an edge to. Nothing here says anything global.
fact TaskCreation {
  all t: Task | no t.parent implies { t.stage = t.workflow.entry and t.kind = Pipelined }
  all t: Task | some t.parent implies t.workflow = t.parent.workflow
  -- a pipelined child moves along a declared stage edge
  all t: Task | (some t.parent and t.kind = Pipelined) implies
    t.stage in t.parent.stage.next
  -- a consult is owned by a role its asker's stage is declared to consult
  all t: Task | t.kind = Consult implies {
    some t.parent
    t.stage in t.workflow.stages
    some r: t.parent.stage.consults | t.stage.needs in r.provides
  }
  all t: Task | t not in t.^parent
}

-- PRD-003: a consult is a leaf. It answers a question and creates nothing, not
-- another consult and not pipeline work either. This is the whole deadlock
-- story: waiting is bounded by depth rather than by the shape of the consult
-- graph, which is allowed to point backwards.
fact ConsultsAreLeaves {
  all t: Task | t.kind = Consult implies no c: Task | c.parent = t
}

/* ---------- what the documents claim ---------- */

-- PRD-003 constraint: "main is checked out by nothing and exists only as a
-- ref". Claimed as a constraint; here it has to FOLLOW from the ACL layout.
assert MainIsCheckedOutNowhere {
  no w: Worktree | w.checkedOut = Main
}

-- ADR-010: "only the supervisor advances main is a property of the filesystem
-- rather than a rule a role follows".
assert NoRoleCanWriteMain {
  all r: Role | Main not in writable[r]
}

-- ADR-010: branches are partitioned, so one role cannot move another's.
assert NoTwoRolesShareAWritableBranch {
  all disj a, b: Role | no branches[a] & branches[b]
}

-- Where the widening stops. Two roles may both write a ref only when it is one
-- of the shared spaces; every other ref stays partitioned. This is the whole
-- content of "the record and the claims are open, and nothing else is".
assert TheWideningStopsAtTheSharedSpaces {
  all disj a, b: Role | (writable[a] & writable[b]) in Shared
}

-- ADR-023: a holder can renew and release its own claim, which is only true
-- because the claim space is shared. Without the widening this is SAT.
assert AHolderCanWriteItsOwnClaim {
  all c: Claim | c.ref in writable[c.holder]
}

-- Branches stay partitioned even though work changes hands, so two roles never
-- commit to one branch.
assert NoTwoRolesShareAnAttemptBranch {
  all disj a, b: Attempt | a.by != b.by implies a.branch != b.branch
}

-- PRD-003: "depth is bounded by the number of stages rather than by a counter".
-- True of the pipeline only. A consult deliberately points backwards, so it
-- revisits a stage by design, and depth is bounded there by consults being
-- leaves instead. Checked over pipelined chains.
fun pipelinedParent: Task -> Task { { c, p: Task | c.parent = p and c.kind = Pipelined } }

assert PipelinedCascadeNeverRevisitsAStage {
  all t: Task | t.kind = Pipelined implies t.stage not in t.^pipelinedParent.stage
}

-- Every task sits somewhere its own workflow declares, consults included.
assert TaskStageBelongsToItsWorkflow {
  all t: Task | t.stage in t.workflow.stages
}

-- A pipelined task's stage is reachable from the entry stage. The creation
-- rule is local; this is the global claim it implies.
assert PipelinedStageReachableFromEntry {
  all t: Task | t.kind = Pipelined implies t.stage in t.workflow.entry.*next
}

-- ADR-015: "a stage resolves to the roles that provide its capability, and to
-- none when nothing does" -- so every declared task has someone who can work
-- it, which is what naming a role gave for free and a capability must earn.
assert EveryTaskHasACapableRole {
  all t: Task | some capable[t.stage]
}

-- ADR-015's sticky taker is gone, and its two assertions with it. What
-- replaces them is a witness below: work CAN change hands now, and a model in
-- which it could not would be modelling the design that was replaced.

-- ADR-015 decision 1: work only ever reaches a role that declared it can do it.
assert NoRoleWorksOutsideWhatItProvides {
  all a: Attempt | a.task.stage.needs in a.by.provides
}

-- PRD-003: "no chain of roles waiting on each other can close into a loop no
-- matter what the declared graph allows". A task waits on the consults it
-- created; that relation must be acyclic even though the consult GRAPH is not.
assert WaitingNeverFormsALoop {
  let waitsOn = { a, b: Task | b.parent = a and b.kind = Consult } |
    no t: Task | t in t.^waitsOn
}

-- PRD-003: a consult is answered by a role the asker was declared to consult,
-- never by one it was not.
assert ConsultsFollowTheDeclaredGraph {
  all t: Task | t.kind = Consult implies
    some r: t.parent.stage.consults | t.stage.needs in r.provides
}

-- ADR-027 point 4: "a role can write a line that lies about what it did; it
-- cannot write a line that lies about who it is". The uid on an entry
-- identifies exactly one role, and it is the one that wrote it.
assert NoRoleWritesAnothersLedgerEntry {
  all e: Entry, r: Role | e.stamped = r.uid implies e.writer = r
}

-- ADR-027 point 4: "nothing writes the ledger as a plain file under a role's
-- uid, which would be a record a role could edit".
assert NoRoleOwnsTheLedgerItWrites {
  all r: Role | r.ledger.pathOwner != r.uid
}

-- ADR-027 point 3: the transcript is "not in the role's worktree, for the
-- reason ADR-026 point 2 keeps the console socket out of it: a worktree is a
-- git working tree the role commits from". A transcript that were one would be
-- prompts and file contents committed to the repository and pushed with it.
assert NoTranscriptIsSomethingARoleCommitsFrom {
  no Role.transcript & Worktree.at
}

-- The same for the ledger, and for the same reason.
assert NoLedgerIsSomethingARoleCommitsFrom {
  no Role.ledger & Worktree.at
}

-- ADR-027 point 3: "the supervisor is content-blind and stays so". Point 12
-- gives it no reader, so this has to follow from what it holds rather than
-- from what it is trusted to avoid opening.
assert TheSupervisorReachesNoTranscript {
  no Supervisor.reads & Role.transcript
}

-- The consult graph is allowed to point backwards. Confirm the model permits
-- it, so ConsultsAreLeaves is not quietly doing the work acyclicity would.
run ConsultCanPointBackwards {
  some s1, s2: Stage | s1 in s2.^next and
    some r: s2.consults | s1.needs in r.provides
  some t: Task | t.kind = Consult
} for 6 but 18 Path

check MainIsCheckedOutNowhere for 6 but 18 Path
check NoRoleCanWriteMain for 6 but 18 Path
check NoTwoRolesShareAWritableBranch for 6 but 18 Path
check TheWideningStopsAtTheSharedSpaces for 6 but 18 Path
check AHolderCanWriteItsOwnClaim for 6 but 18 Path
check NoTwoRolesShareAnAttemptBranch for 6 but 18 Path
check PipelinedCascadeNeverRevisitsAStage for 6 but 18 Path
check TaskStageBelongsToItsWorkflow for 6 but 18 Path
check PipelinedStageReachableFromEntry for 6 but 18 Path
check EveryTaskHasACapableRole for 6 but 18 Path
check NoRoleWorksOutsideWhatItProvides for 6 but 18 Path
check WaitingNeverFormsALoop for 6 but 18 Path
check ConsultsFollowTheDeclaredGraph for 6 but 18 Path
check NoRoleWritesAnothersLedgerEntry for 6 but 18 Path
check NoRoleOwnsTheLedgerItWrites for 6 but 18 Path
check NoTranscriptIsSomethingARoleCommitsFrom for 6 but 18 Path
check NoLedgerIsSomethingARoleCommitsFrom for 6 but 18 Path
check TheSupervisorReachesNoTranscript for 6 but 18 Path

-- ADR-015 decision 2: fan-out parallelises. Two tasks at one stage, taken by
-- two different roles, has to be a legal configuration -- it is the whole
-- point of the change, and a model that forbade it would be modelling the
-- pipeline this replaces.
-- ADR-023 decision 6: work no longer sticks. Two attempts at one task by two
-- different roles is now a legal configuration, and this SAT is the evidence
-- that the sticky-taker fact really is gone rather than merely unstated.
run WorkCanChangeHands {
  some disj a, b: Attempt | a.task = b.task and a.by != b.by
} for 6 but 18 Path

-- ADR-023 decision 2, stated as something reachable rather than as prose: a
-- role that does not hold a claim can still write it. The compare-and-swap
-- stops two agents racing; it does not stop one from deleting a peer's claim.
run APeerCanWriteAnothersClaim {
  some c: Claim | some r: Role | r != c.holder and c.ref in writable[r]
} for 6 but 18 Path

run FanOutReachesTwoRoles {
  some disj t1, t2: Task | t1.stage = t2.stage and
    some disj a1, a2: Attempt | a1.task = t1 and a2.task = t2 and a1.by != a2.by
} for 6 but 18 Path

-- A generalist providing several capabilities can be pulled into stages of
-- different workflows. ADR-015 accepts this and says the record will show it.
run OneRoleCoversTwoStages {
  some r: Role | {
    #r.provides > 1
    some disj s1, s2: Stage | s1.needs != s2.needs and
      r in capable[s1] and r in capable[s2]
  }
} for 6 but 18 Path

-- ADR-027's first consequence, stated as something reachable rather than as
-- prose: one journal holds entries from several roles, which is what makes a
-- flood by one of them an eviction of the rest. Point 6 buys a bucket per
-- factory and not one per role, and this SAT is that cost.
run OneJournalHoldsSeveralRolesEntries {
  some disj e, f: Entry | e.writer != f.writer
} for 6 but 18 Path

-- Not vacuous: a role really does hold three separate places, so the
-- assertions above are about a configuration the model can build.
run ARoleHoldsAWorktreeALedgerAndATranscript {
  some r: Role | #(r.tree.at + r.ledger + r.transcript) = 3
  some Entry
} for 6 but 18 Path

-- Not vacuous: a factory with several roles, a real cascade, and a pipeline of
-- more than one stage is possible.
run NonTrivialFactory {
  #Role > 2
  some t: Task | some t.parent.parent
  some w: Workflow | #w.stages > 2
} for 6 but 18 Path
