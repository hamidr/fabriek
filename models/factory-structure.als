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
sig Stage { ownedBy: one Role, next: set Stage }

sig Task {
  workflow: one Workflow,
  stage: one Stage,
  parent: lone Task,
  state: one TaskState
}
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
  all s: Stage | s not in s.^next
  all s: Stage | one w: Workflow | s in w.stages
}

-- PRD-003: the local rule for creating work. A root task sits at the entry
-- stage; a created task inherits the workflow and sits at a stage its parent's
-- stage has an edge to. Nothing here says anything global.
fact TaskCreation {
  all t: Task | no t.parent implies t.stage = t.workflow.entry
  all t: Task | some t.parent implies {
    t.workflow = t.parent.workflow
    t.stage in t.parent.stage.next
  }
  all t: Task | t not in t.^parent
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

-- PRD-003: "depth is bounded by the number of stages rather than by a counter
-- the supervisor keeps at run time". If true, no cascade can revisit a stage.
assert CascadeNeverRevisitsAStage {
  all t: Task | t.stage not in t.^parent.stage
}

-- PRD-003: a task always sits somewhere its own pipeline declares, reachable
-- from the entry stage. The creation rule is local; this is the global claim.
assert TaskStageReachableFromEntry {
  all t: Task | t.stage in t.workflow.entry.*next
}

-- PRD-003: every task has a role that will run it.
assert EveryTaskHasAnOwningRole {
  all t: Task | one t.stage.ownedBy
}

check MainIsCheckedOutNowhere for 6
check NoRoleCanWriteMain for 6
check NoTwoRolesShareAWritableRef for 6
check CascadeNeverRevisitsAStage for 6
check TaskStageReachableFromEntry for 6
check EveryTaskHasAnOwningRole for 6

-- Not vacuous: a factory with several roles, a real cascade, and a pipeline of
-- more than one stage is possible.
run NonTrivialFactory {
  #Role > 2
  some t: Task | some t.parent.parent
  some w: Workflow | #w.stages > 2
} for 6
