// The lifecycle of a factory's own machine, as decided in
// docs/ADR-019-fabriek-owns-a-factory-vm.md and redrawn by
// docs/ADR-057-the-machine-is-an-appliance-and-a-factory-arrives-as-toml.md:
// one image for every factory, the factory handed over as credentials at
// boot, and a prepare step after boot that reads them, renders the
// machine's files and realises a profile per role before any session
// starts. Nothing is built per factory, so a changed declaration is a new
// credential and a restart, never a rebuild.
//
// The states are absent, ready (disks made, credentials written), booting,
// booted (reachable, unprepared), preparing, running (prepared) and
// stopping. Two sides interleave: the host writes credentials, boots and
// stops; inside the machine prepare realises profiles one role at a time
// and may fail between two of them, and role sessions come and go and
// write to the pool.
//
// Three properties carry over from ADR-017 and ADR-019: nothing fabriek does
// ends a machine mid-write, the disk outlives everything but destroy, and a
// machine runs what it booted with. Two are ADR-057's own: a role's session
// starts only on a profile prepare made for the credentials this boot
// carries, and prepare is idempotent from any half state.
//
// What this model found (2026-09-16): the prepared flag that gates the
// executor lived on the pool, so a reboot with new credentials came up with
// last boot's flag and the executor could start a session on a stale
// profile. The flag is per boot now (preparedGen below is reset at boot).
module vmLifecycle {
  // How many times the operator may move the pin. Bounds the state space;
  // six is enough to drift, restart and drift again with samples to spare.
  pure val maxCredGen = 6
  pure val roles = Set("backend", "reviewer")

  var vmState: str
  var diskExists: bool

  // The credentials on the host, the ones the running machine booted with,
  // and the ones the machine's prepared state was rendered from (0: none).
  var credGen: int
  var bootedGen: int
  var preparedGen: int

  // Which roles have a profile, and from which credentials each was made.
  // A profile outlives a boot (it is in the store overlay), which is why it
  // carries its generation: one made for old credentials is not one for new.
  var profileGen: str -> int

  var sessions: Set[str]
  var writing: bool

  // Witnesses. The first must stay false; the others are states the design
  // has to be able to reach.
  var lostToAbruptHostStop: bool
  var staleReached: bool
  var halfPreparedReached: bool

  def up(s: str): bool =
    s == "booting" or s == "booted" or s == "preparing" or s == "running" or s == "stopping"

  action holdMachine = all { vmState' = vmState, diskExists' = diskExists }
  action holdGens = all {
    credGen' = credGen, bootedGen' = bootedGen, preparedGen' = preparedGen,
    profileGen' = profileGen,
  }
  action holdGuest = all { sessions' = sessions, writing' = writing }
  action holdWitness = all {
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = staleReached,
    halfPreparedReached' = halfPreparedReached,
  }

  action init = all {
    vmState' = "absent",
    diskExists' = false,
    credGen' = 1,
    bootedGen' = 0,
    preparedGen' = 0,
    profileGen' = roles.mapBy(_ => 0),
    sessions' = Set(),
    writing' = false,
    lostToAbruptHostStop' = false,
    staleReached' = false,
    halfPreparedReached' = false,
  }

  // fabriek up on a factory that has no machine yet: the disks are made and
  // the credentials written from the operator's config and the pin. The
  // image is nobody's to build here; it exists once.
  action ready = all {
    vmState == "absent",
    vmState' = "ready",
    diskExists' = true,
    holdGens, holdGuest, holdWitness,
  }

  action boot = all {
    vmState == "ready",
    diskExists,
    vmState' = "booting",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // The machine is reachable and carries the host's credentials as of this
  // boot. Nothing of last boot's prepared state counts: the flag the
  // executor waits on is per boot, so preparedGen is 0 until prepare ends.
  // The profiles in the store overlay stay, with the generation they were
  // made for.
  action booted = all {
    vmState == "booting",
    vmState' = "booted",
    diskExists' = diskExists,
    credGen' = credGen, bootedGen' = credGen, preparedGen' = 0,
    profileGen' = profileGen,
    holdGuest, holdWitness,
  }

  // A boot that fails leaves the disk alone, which is what makes retrying it
  // safe rather than a second chance at losing the pool.
  action bootFailed = all {
    vmState == "booting",
    vmState' = "ready",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // factory-prepare starts, on a fresh boot or again after a failure.
  action prepare = all {
    vmState == "booted",
    vmState' = "preparing",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // One role's profile realised for this boot's credentials. A profile made
  // for the same credentials is found in the store and kept: prepare is
  // idempotent, so this is a no-op on a role already done.
  action prepareRole = all {
    vmState == "preparing",
    nondet r = roles.oneOf()
    all {
      profileGen' = profileGen.set(r, bootedGen),
      credGen' = credGen, bootedGen' = bootedGen, preparedGen' = preparedGen,
    },
    holdMachine, holdGuest, holdWitness,
  }

  // Prepare fails between two roles: a devShell that does not substitute, a
  // declaration the schema refuses. The machine stays reachable and
  // unprepared, with whatever profiles it made kept, and up reports it.
  action prepareFailed = all {
    vmState == "preparing",
    vmState' = "booted",
    diskExists' = diskExists,
    holdGens, holdGuest,
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = staleReached,
    halfPreparedReached' = (halfPreparedReached or
      (roles.exists(r => profileGen.get(r) == bootedGen) and
       roles.exists(r => profileGen.get(r) != bootedGen))),
  }

  // Every role has a profile for this boot's credentials: prepare writes the
  // flag and the executor may start.
  action prepared = all {
    vmState == "preparing",
    roles.forall(r => profileGen.get(r) == bootedGen),
    vmState' = "running",
    diskExists' = diskExists,
    credGen' = credGen, bootedGen' = bootedGen, preparedGen' = bootedGen,
    profileGen' = profileGen,
    holdGuest, holdWitness,
  }

  // The executor starts a role's session: only once prepared, and only for a
  // role whose profile link exists.
  action startSession = all {
    vmState == "running",
    nondet r = roles.oneOf()
    all {
      not(sessions.contains(r)),
      profileGen.get(r) == bootedGen,
      sessions' = sessions.union(Set(r)),
    },
    writing' = writing,
    holdMachine, holdGens, holdWitness,
  }

  action beginWrite = all {
    vmState == "running",
    sessions.size() > 0,
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
    sessions.size() > 0,
    not(writing),
    nondet r = sessions.oneOf()
    sessions' = sessions.exclude(Set(r)),
    writing' = false,
    holdMachine, holdGens, holdWitness,
  }

  action requestStop = all {
    vmState == "running" or vmState == "booted",
    vmState' = "stopping",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // The stop cannot complete because the machine is still busy. Reported,
  // never forced: the machine goes back to running.
  action stopBlocked = all {
    vmState == "stopping",
    sessions.size() > 0 or writing,
    vmState' = "running",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  action shutdownComplete = all {
    vmState == "stopping",
    sessions.size() == 0,
    not(writing),
    vmState' = "ready",
    diskExists' = diskExists,
    holdGens, holdGuest, holdWitness,
  }

  // The host loses power, or somebody kills the hypervisor. Not something
  // fabriek does; the residual risk ADR-017 puts ZFS underneath.
  action abruptHostStop = all {
    up(vmState),
    vmState' = "ready",
    diskExists' = diskExists,
    holdGens,
    sessions' = Set(),
    writing' = false,
    lostToAbruptHostStop' = (lostToAbruptHostStop or writing),
    staleReached' = staleReached,
    halfPreparedReached' = halfPreparedReached,
  }

  // fabriek up -u: the pin moves, the credentials on the host change. A
  // machine running on the old ones is stale until it is restarted.
  action updateCredentials = all {
    credGen < maxCredGen,
    credGen' = credGen + 1,
    bootedGen' = bootedGen, preparedGen' = preparedGen, profileGen' = profileGen,
    holdMachine, holdGuest,
    lostToAbruptHostStop' = lostToAbruptHostStop,
    staleReached' = (staleReached or (vmState == "running" and bootedGen < credGen + 1)),
    halfPreparedReached' = halfPreparedReached,
  }

  action destroy = all {
    vmState == "ready",
    sessions.size() == 0,
    vmState' = "absent",
    diskExists' = false,
    credGen' = credGen, bootedGen' = 0, preparedGen' = 0,
    profileGen' = roles.mapBy(_ => 0),
    holdGuest, holdWitness,
  }

  action step = any {
    ready, boot, booted, bootFailed,
    prepare, prepareRole, prepareFailed, prepared,
    startSession, beginWrite, endWrite, endSession,
    requestStop, stopBlocked, shutdownComplete,
    abruptHostStop, updateCredentials, destroy,
  }

  // A session exists only inside a machine that is up and prepared.
  val noSessionOutsideAPreparedMachine: bool =
    sessions.size() == 0 or (vmState == "running" or vmState == "stopping")

  // Nothing is ever up without the storage its state lives on.
  val noMachineWithoutItsDisk: bool = not(up(vmState)) or diskExists

  // The disk outlives every transition except the one that exists to remove
  // it: a failed boot, a failed prepare, a stop, an abrupt host stop.
  val diskOutlivesEverythingButDestroy: bool =
    vmState == "absent" or diskExists

  // ADR-057 point 5: a role's session runs on a profile made for the
  // credentials this boot carries, never on last boot's, and never before
  // prepare finished for this boot.
  val sessionOnlyOnThisBootsProfile: bool =
    sessions.forall(r => profileGen.get(r) == bootedGen and preparedGen == bootedGen)

  // A prepared machine has every role's profile for its own credentials:
  // the flag means what it says.
  val preparedMeansEveryProfile: bool =
    vmState != "running" or roles.forall(r => profileGen.get(r) == bootedGen)

  val allInvariants: bool = and {
    noSessionOutsideAPreparedMachine,
    noMachineWithoutItsDisk,
    diskOutlivesEverythingButDestroy,
    sessionOnlyOnThisBootsProfile,
    preparedMeansEveryProfile,
  }

  // Witness, stated as a negation so a violation is the evidence: the
  // credentials can move ahead of the machine running them.
  val neverStale: bool = not(staleReached)

  // Witness: a stale machine becomes current again by stopping and booting,
  // with prepare realising what the new credentials need.
  val neverCurrentAgainAfterStale: bool =
    not(staleReached and vmState == "running" and bootedGen == credGen)

  // Witness: prepare can stop halfway, with some profiles for this boot and
  // some not. If this never violates, the model has no half state and the
  // idempotence claim is untested.
  val neverHalfPrepared: bool = not(halfPreparedReached)

  // Witness: a machine half prepared and then prepared again reaches running
  // with every profile, which is the idempotence ADR-057 point 4 claims.
  val neverRecoveredFromHalf: bool =
    not(halfPreparedReached and vmState == "running")

  // Witness: the one way left to end a machine mid-write is the host dying.
  val neverLostToAbruptHostStop: bool = not(lostToAbruptHostStop)
}
