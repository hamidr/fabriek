// Who may reach what, and what carries the credential, as decided in
// docs/ADR-025-the-machine-holds-the-model-credential.md.
//
// ADR-009 gave an unattended run no forwarded agent and a signing key of its
// own, and said the run "cannot authenticate anywhere". That was true and is
// no longer reachable: an agent that runs a model needs a credential for it.
// The question this model answers is whether the credential can be kept out of
// the cage while the turn still works, and whether ADR-009's actual property
// survives the change.
//
// The shape is a permission model, which is one the Formal Modeling Gate
// names, and it is structural rather than temporal: what configurations of
// holding and reaching are legal, not what happens over time. Alloy, not Quint.
module egressAuthority

// Scope 10, not 6: with the daemon and the substituter there are seven named
// atoms before a second role or a second host exists at all.
//
// Everything that can be an endpoint of a permitted connection. Roles, the
// proxy and the supervisor are principals; the model API and a git remote are
// destinations. The edge relation is what the machine's firewall permits, not
// what anybody intends.
abstract sig Node { edge: set Node }

abstract sig Principal extends Node { holds: set Credential }
sig Role extends Principal {}
one sig Proxy extends Principal {}
one sig Supervisor extends Principal {}

// nixcage binds /nix/var/nix/daemon-socket into every session, which is what
// lets a role's `nix build` happen without the cage having a network. The
// daemon is therefore something every role can reach and something that
// fetches, and leaving it out of this model was leaving out the one way a
// cage reaches a host without going near the proxy.
one sig NixDaemon extends Principal {}

abstract sig Destination extends Node {}
one sig ModelApi extends Destination {}
one sig GitRemote extends Destination {}
one sig Substituter extends Destination {}
sig OtherHost extends Destination {}

// A credential opens the destinations it authenticates to. A signing key opens
// nothing, which is the whole of why ADR-009 could give one to a cage.
sig Credential { opens: set Destination }
one sig ModelKey extends Credential {}
sig SigningKey extends Credential {}

fact destinationsAreLeaves { no Destination.edge }
fact thereAreRoles { some Role }

// Decision 1. The model credential is held by the machine's proxy and by
// nothing else. Not bound into a cage, not in a role's environment.
fact keyLivesOnlyAtTheProxy { ModelKey.~holds = Proxy }

// ADR-009, unchanged: a signing key produces a signature and authenticates to
// no host. This is the fact that made a key in a cage acceptable then, and it
// is what makes a role's holdings harmless now.
fact signingKeysOpenNothing { no SigningKey.opens }
fact theModelKeyOpensTheModelApi { ModelKey.opens = ModelApi }

// A role holds its own signing key and nothing else, and no two roles hold the
// same one, so a signature stays attributable to one role (ADR-009).
fact rolesHoldOnlyTheirOwnSigningKey {
  all r: Role | r.holds in SigningKey
  all disj a, b: Role | no a.holds & b.holds
}

// Decision 3. The machine's firewall permits a role exactly one destination,
// the proxy's listener, and permits the proxy exactly what its allowlist says.
// A role's processes carry its allocated uid on the machine's network stack,
// which is what makes this rule expressible on the uid rather than on an
// address a cage could choose.
// A role reaches two things and neither is a host: the proxy's listener, and
// the build daemon's socket. Both are on its own machine and both have an
// allowlist of their own.
fact roleEgressIsTheTwoChokepoints { all r: Role | r.edge = Proxy + NixDaemon }
fact proxyEgressIsTheAllowlist { Proxy.edge in ModelApi }

// The daemon fetches on a role's behalf, and a fixed-output derivation names
// the URL it fetches, so a cage that can reach the daemon can make it fetch.
// What stops that being unrestricted egress is that the daemon's own uid is
// held to the substituter by the same firewall that holds the roles.
fact daemonEgressIsTheSubstituter { NixDaemon.edge in Substituter }

// The supervisor reads declarations and metadata. It is uncaged, and it is not
// a way out of the machine either.
fact theSupervisorIsNotAWayOut { no Supervisor.edge }

// There is deliberately no fact saying a principal reaches only what it holds
// a credential for. That would be the property being checked, written as an
// assumption, which is how ADR-023's model missed its race. Reaching a host is
// not the same as authenticating to it: a cage with a route to any host can
// post whatever it likes to a listener that asks for nothing, and a 401 is
// returned after the request body has already arrived. The firewall is the
// only thing between a role and a host, so the firewall is what gets checked.

// What has to hold for the decision to be worth anything.
assert noRoleHoldsAnAuthenticatingCredential { all r: Role | no r.holds.opens }
assert noRoleReachesTheModelApi { all r: Role | ModelApi not in r.edge }
assert noRoleReachesTheSubstituterDirectly {
  all r: Role | Substituter not in r.edge
}
assert noRoleReachesAGitRemote { all r: Role | GitRemote not in r.^edge }
assert noRoleReachesAnyOtherHost { all r: Role, h: OtherHost | h not in r.^edge }

// The bypass check. Delete the proxy's outgoing edges; if the model API is
// still reachable from a role, there is a second way out and the proxy is a
// convention rather than a chokepoint.
assert everyModelCallTransitsTheProxy {
  all r: Role | ModelApi not in r.^(edge - (Proxy -> Node))
}

// Whoever opens the connection to the model holds the key. Nothing asserts
// this directly; it has to fall out of the firewall permitting only the proxy
// that edge, which is what makes the injection an enforcement point rather
// than an intention.
assert onlyTheProxyPresentsTheKey {
  all n: Node | ModelApi in n.edge implies ModelKey in n.holds
}

// ADR-009's property, restated for a world with a credential in it: a role
// still holds nothing that reaches any host.
assert adr009Survives {
  all r: Role, d: Destination | d not in r.holds.opens
}

check noRoleHoldsAnAuthenticatingCredential for 10
check noRoleReachesTheModelApi for 10
check noRoleReachesTheSubstituterDirectly for 10
check noRoleReachesAGitRemote for 10
check noRoleReachesAnyOtherHost for 10
check everyModelCallTransitsTheProxy for 10
check onlyTheProxyPresentsTheKey for 10
check adr009Survives for 10

// The channel this model was missing, stated as a run rather than hidden by a
// fact. A role reaches a host it did not declare and the proxy never saw it,
// by asking the build daemon to fetch. What bounds it is where the daemon may
// reach, not whether the role may ask.
run aRoleReachesAHostWithoutTheProxy {
  some r: Role | some d: Destination |
    d in r.^edge and d not in r.^(edge - (Proxy -> Node))
} for 10

// And that the design is not merely safe by being empty. A factory in which
// no role can reach the proxy, or the proxy cannot reach the model, satisfies
// every assertion above and does no work.
run aRoleReachesTheProxy { some r: Role | Proxy in r.edge } for 10
run theProxyReachesTheModelApi { ModelApi in Proxy.edge } for 10
run severalRolesEachWithTheirOwnKey { #Role > 1 and all r: Role | some r.holds } for 10
