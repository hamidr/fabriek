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

// Everything that can be an endpoint of a permitted connection. Roles, the
// proxy and the supervisor are principals; the model API and a git remote are
// destinations. The edge relation is what the machine's firewall permits, not
// what anybody intends.
abstract sig Node { edge: set Node }

abstract sig Principal extends Node { holds: set Credential }
sig Role extends Principal {}
one sig Proxy extends Principal {}
one sig Supervisor extends Principal {}

abstract sig Destination extends Node {}
one sig ModelApi extends Destination {}
one sig GitRemote extends Destination {}
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
fact roleEgressIsTheProxyAlone { all r: Role | r.edge = Proxy }
fact proxyEgressIsTheAllowlist { Proxy.edge in ModelApi }

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

check noRoleHoldsAnAuthenticatingCredential for 6
check noRoleReachesTheModelApi for 6
check noRoleReachesAGitRemote for 6
check noRoleReachesAnyOtherHost for 6
check everyModelCallTransitsTheProxy for 6
check onlyTheProxyPresentsTheKey for 6
check adr009Survives for 6

// And that the design is not merely safe by being empty. A factory in which
// no role can reach the proxy, or the proxy cannot reach the model, satisfies
// every assertion above and does no work.
run aRoleReachesTheProxy { some r: Role | Proxy in r.edge } for 6
run theProxyReachesTheModelApi { ModelApi in Proxy.edge } for 6
run severalRolesEachWithTheirOwnKey { #Role > 1 and all r: Role | some r.holds } for 6
