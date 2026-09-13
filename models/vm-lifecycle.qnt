// The lifecycle of a factory's own machine, as decided in
// docs/ADR-019-fabriek-owns-a-factory-vm.md and required by phase 2 of
// docs/PRD-004-a-factory-of-its-own.md, amended for the redesign (ADR-033 to ADR-040)
// decision 15 (docs/roadmap.md 0.3): the declaration is built into the image,
// so every edit to it is a rebuild, and what drains before one is the tasks
// in flight rather than the roles, which are permanent and lose nothing.
//
// fabriek builds and runs one NixOS VM per factory. The states are absent,
// built, booting, running and stopping, and two sides interleave across them:
// the host builds, boots, resizes and stops, while inside the machine role
// sessions come and go and write to the pool the factory's state lives on.
//
// ADR-017 exists because a VM was ended rather than shut down and worktrees
// came back empty. fabriek now owns the stopping, so the property that
// matters most here is that nothing fabriek does ends a machine that is
// mid-write. A stop that cannot complete is reported and the machine keeps
// running, which is why there is no action in this model that forces one.
module vmLifecycle {
  // How many times the repository's declaration may be edited. Bounds the
  // state space; three is enough to build, drift, rebuild and drift again.
  pure val maxDeclGen = 3
  pure val maxSessions = 2

  var vmState: str
  var diskExists: bool

  // The declaration in the repository, the generation the image was built
  // from, and the generation the machine now running actually booted with.
  var declGen: int
  var builtGen: int
  var appliedGen: int

  var sessions: int
  var writing: bool

  // Witnesses. The first two must stay false; the last two are states the
  // design has to be able to reach.
  var builtGenChangedWhileRunning: bool
  var staleReached: bool
  var lostToAbruptHostStop: bool

  def up(s: str): bool = s == "booting" or s == "running" or s == "stopping"

  action holdMachine = all {
    vmState' = vmState, diskExists' = diskExists,
  }
  action holdGens = all {
    declGen' = declGen, builtGen' = builtGen, appliedGen' = appliedGen,
  }
  action holdGuest = all { sessions' = sessions, writing' = writing }
  action holdWitness = all {
    builtGenChangedWhileRunning' = builtGenChangedWhileRunning,
    staleReached' = staleReached,
    lostToAbruptHostStop' = lostToAbruptHostStop,
  }

  action init = all {
    vmState' = "absent",
    diskExists' = false,
    declGen' = 0,
    builtGen' = 0,
    appliedGen' = 0,
    sessions' = 0,
    writing' = false,
    builtGenChangedWhileRunning' = false,
    staleReached' = false,
    lostToAbruptHostStop' = false,
  }

  // fabriek up on a factory that has no machine yet: the disk is made and
  // the image is built from the declaration as it stands.
  action build = all {
    vmState == "absent",
    vmState' = "built",
    diskExists' = true,
    declGen' = declGen, builtGen' = declGen, appliedGen' = appliedGen,
    holdGuest, holdWitness,
  }

  // The declaration changed, and under decision 15 every part of it is in the
  // image: resources, roles, workflows and devShells alike. This is the
  // normal path after an edit, not the exception it was when roles and
  // workflows were read at run time (ADR-020 point 3, withdrawn).
  action rebuild = all {
    vmState == "built",
    builtGen != declGen,
    diskExists,
    holdMachine,
    declGen' = declGen, builtGen' = declGen, appliedGen' = appliedGen,
    holdGuest,
    builtGenChangedWhileRunning' = (builtGenChangedWhileRunning or vmState == "running"),
    staleReached' = staleReached,
    lostToAbruptHostStop' = lostToAbruptHostStop,
  }

  action boot = all {
    vmState == "built",
    diskExists,
    vmState' = "booting",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  action booted = all {
    vmState == "booting",
    vmState' = "running",
    diskExists' = diskExists,
    declGen' = declGen, builtGen' = builtGen, appliedGen' = builtGen,
    holdGuest, holdWitness,
  }

  // A boot that fails leaves the disk alone, which is what makes retrying it
  // safe rather than a second chance at losing the pool.
  action bootFailed = all {
    vmState == "booting",
    vmState' = "built",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  action startSession = all {
    vmState == "running",
    sessions < maxSessions,
    sessions' = sessions + 1,
    writing' = writing,
    holdMachine, holdGens, holdWitness,
  }

  action beginWrite = all {
    vmState == "running",
    sessions > 0,
    not(writing),
    writing' = true,
    sessions' = sessions,
    holdMachine, holdGens, holdWitness,
  }

  action endWrite = all {
    writing,
    writing' = false,
    sessions' = sessions,
    holdMachine, holdGens, holdWitness,
  }

  action endSession = all {
    sessions > 0,
    not(writing),
    sessions' = sessions - 1,
    writing' = false,
    holdMachine, holdGens, holdWitness,
  }

  action requestStop = all {
    vmState == "running",
    vmState' = "stopping",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // The stop cannot complete because the machine is still busy. PRD-004 requires
  // this to be reported rather than forced, so the machine goes back to
  // running and there is no action here that ends it anyway.
  action stopBlocked = all {
    vmState == "stopping",
    sessions > 0 or writing,
    vmState' = "running",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  action shutdownComplete = all {
    vmState == "stopping",
    sessions == 0,
    not(writing),
    vmState' = "built",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // The host loses power, or somebody kills the hypervisor. Not something
  // fabriek does; the residual risk ADR-017 puts ZFS underneath.
  action abruptHostStop = all {
    up(vmState),
    vmState' = "built",
    diskExists' = diskExists,
    holdGens,
    sessions' = 0,
    writing' = false,
    builtGenChangedWhileRunning' = builtGenChangedWhileRunning,
    staleReached' = staleReached,
    lostToAbruptHostStop' = (lostToAbruptHostStop or writing),
  }

  action editDeclaration = all {
    declGen < maxDeclGen,
    declGen' = declGen + 1,
    builtGen' = builtGen, appliedGen' = appliedGen,
    holdMachine, holdGuest,
    builtGenChangedWhileRunning' = builtGenChangedWhileRunning,
    staleReached' = (staleReached or (vmState == "running" and appliedGen < declGen + 1)),
    lostToAbruptHostStop' = lostToAbruptHostStop,
  }

  action destroy = all {
    vmState == "built",
    sessions == 0,
    vmState' = "absent",
    diskExists' = false,
    declGen' = declGen, builtGen' = 0, appliedGen' = 0,
    holdGuest, holdWitness,
  }

  action step = any {
    build, rebuild, boot, booted, bootFailed,
    startSession, beginWrite, endWrite, endSession,
    requestStop, stopBlocked, shutdownComplete,
    abruptHostStop, editDeclaration, destroy,
  }

  // A session exists only inside a machine that is up.
  val noSessionOutsideAMachine: bool =
    sessions == 0 or (vmState == "running" or vmState == "stopping")

  // Nothing is ever up without the storage its state lives on.
  val noMachineWithoutItsDisk: bool = not(up(vmState)) or diskExists

  // A rebuild happens to a machine that is not running, so a task mid-write
  // is never rebuilt out from under. What drains before the stop is the
  // sessions, one per task in flight; a role's dataset, home and key are on
  // the pool and survive the rebuild untouched (decision 15).
  val resizeNeedsAStoppedMachine: bool = not(builtGenChangedWhileRunning)

  // The disk outlives every transition except the one that exists to remove
  // it, so a failed boot, a stop, an abrupt host stop and a rebuild all keep
  // the factory's state. Stated over the state rather than as a flag nothing
  // sets, because a flag nothing sets is an invariant that cannot fail.
  val diskOutlivesEverythingButDestroy: bool =
    vmState == "absent" or diskExists

  // A machine runs what it booted with. A declaration edited underneath it
  // does not change it, which is what makes stale a state rather than a race.
  val runningMachineMatchesItsImage: bool =
    vmState != "running" or appliedGen == builtGen

  val allInvariants: bool = and {
    noSessionOutsideAMachine,
    noMachineWithoutItsDisk,
    resizeNeedsAStoppedMachine,
    diskOutlivesEverythingButDestroy,
    runningMachineMatchesItsImage,
  }

  // Witness, stated as a negation so a violation is the evidence: the
  // declaration can drift ahead of the machine running it. A model where this
  // never violates has no stale state and is not modelling this design.
  val neverStale: bool = not(staleReached)

  // Witness: a stale machine becomes current again, by draining, stopping,
  // rebuilding and booting. This is decision 15's normal path; if it never
  // violates, an edited declaration has no way back onto the machine.
  val neverCurrentAgainAfterStale: bool =
    not(staleReached and vmState == "running" and appliedGen == declGen)

  // Witness: the one way left to end a machine mid-write is the host dying,
  // which is what the pool underneath is for. If this never violates, the
  // model has no abrupt stop in it and the ZFS argument is untested.
  val neverLostToAbruptHostStop: bool = not(lostToAbruptHostStop)
}
