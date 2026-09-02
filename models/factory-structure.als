/*
 * Structural invariants of the software factory in
 * docs/PRD-003-software-factory.md, under the ownership and ref rules of
 * docs/ADR-010-role-cage-identity.md.
 *
 * The facts state only what the mechanism gives: one uid and one worktree per
 * role, an ACL that makes a ref writable exactly by the role whose namespace
 * holds it, git requiring write access to the branch a worktree has checked
 * out, and the local rule for where a task may be created. Everything the
 * documents *claim* is an assertion, so a claim that does not follow from the
 * mechanism shows up as SAT.
 */

sig Uid {}

sig Worktree { owner: one Uid, checkedOut: one Ref }

-- ADR-010: a ref lives in at most one role's namespace. refs/heads/main lives
-- in none, which is the whole mechanism behind "main is writable by no cage".
sig Ref { namespace: lone Role }
one sig Main extends Ref {}

sig Role { uid: one Uid, tree: one Worktree }

sig Workflow { stages: set Stage, entry: one Stage }
-- next: pipeline edges, acyclic. consults: who this stage may ask, and it may
-- point backwards, so this relation is deliberately not required acyclic.
sig Stage { ownedBy: one Role, next: set Stage, consults: set Role }

sig Task {
  workflow: one Workflow,
  stage: one Stage,
  parent: lone Task,
  state: one TaskState,
  kind: one TaskKind
}
abstract sig TaskKind {}
one sig Pipelined, Consult extends TaskKind {}
abstract sig TaskState {}
one sig Proposed, Ready, Running, Blocked, AwaitingReview, Done, Failed, Cancelled
  extends TaskState {}

/* ---------- the mechanism ---------- */

fun writable[r: Role]: set Ref { namespace.r }

-- ADR-010 decision 1 and 6: a uid per role, a worktree per role, owned by it.
fact RoleIdentity {
  all disj a, b: Role | a.uid != b.uid
  all disj a, b: Role | a.tree != b.tree
  all r: Role | r.tree.owner = r.uid
  all w: Worktree | some r: Role | r.tree = w
}

-- ADR-010 decision 5: Main is in nobody's namespace.
fact MainHasNoNamespace { no Main.namespace }

-- git: a worktree can only be worked in if its role can write the branch it
-- has checked out. This is a fact about git, not a choice of ours.
fact CommitNeedsAWritableBranch {
  all r: Role | r.tree.checkedOut in writable[r]
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
    t.stage.ownedBy in t.parent.stage.consults
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

-- ADR-010: refs are partitioned, so one role cannot move another's branch.
assert NoTwoRolesShareAWritableRef {
  all disj a, b: Role | no writable[a] & writable[b]
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

-- PRD-003: every task has a role that will run it.
assert EveryTaskHasAnOwningRole {
  all t: Task | one t.stage.ownedBy
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
    t.stage.ownedBy in t.parent.stage.consults
}

-- The consult graph is allowed to point backwards. Confirm the model permits
-- it, so ConsultsAreLeaves is not quietly doing the work acyclicity would.
run ConsultCanPointBackwards {
  some s1, s2: Stage | s1 in s2.^next and s1.ownedBy in s2.consults
  some t: Task | t.kind = Consult
} for 6

check MainIsCheckedOutNowhere for 6
check NoRoleCanWriteMain for 6
check NoTwoRolesShareAWritableRef for 6
check PipelinedCascadeNeverRevisitsAStage for 6
check TaskStageBelongsToItsWorkflow for 6
check PipelinedStageReachableFromEntry for 6
check EveryTaskHasAnOwningRole for 6
check WaitingNeverFormsALoop for 6
check ConsultsFollowTheDeclaredGraph for 6

-- Not vacuous: a factory with several roles, a real cascade, and a pipeline of
-- more than one stage is possible.
run NonTrivialFactory {
  #Role > 2
  some t: Task | some t.parent.parent
  some w: Workflow | #w.stages > 2
} for 6
