# shellcheck shell=bash
## The spec a factory's machine is built from (ADR-040).
##
## Composed where the build runs and not where the operator types: the
## machine flake hands this two files, the declaration as the repository's own
## flake evaluated it and the local facts only the operator's host knows, and
## takes back one JSON document or a refusal naming what was wrong. Validation
## and the clamp are the same functions the operator's side used to run at
## every command, so a bad declaration now fails a build rather than the first
## verb that needed it.
##
## Sourced by store path, beside names.sh, sizes.sh, schema.sh, resources.sh
## and repo-declaration.sh, whose functions this relies on.

## cageworks_machine_spec <declaration.json> <local.json>
##
## local.json carries factory, system, hostSystem, sshPort, authorizedKey, the
## operator's caps, and which header carries which endpoint's credential. The
## credential itself is never here: a spec is built, logged and written beside
## the machine, and a secret in one would be a secret in all three (ADR-025).
cageworks_machine_spec() {
	local declaration_file="$1" local_file="$2"
	local declaration caps

	declaration="$(cageworks_declaration_validate <"$declaration_file")" || return 1

	caps="$(mktemp)"
	jq '.caps // {}' "$local_file" >"$caps"
	declaration="$(printf '%s' "$declaration" | cageworks_resources_clamp "$caps")" || {
		rm -f "$caps"
		return 1
	}
	rm -f "$caps"

	## Memory is declared the way a person writes it and a hypervisor counts
	## it in MiB, so it is converted here rather than anywhere a comparison
	## happens. The ledger's bound likewise (ADR-027 point 8): a machine told
	## nothing falls back to its own bound rather than to none.
	local mem="" journal="" declared
	declared="$(printf '%s' "$declaration" | jq -r '.resources.memory // empty')"
	[ -z "$declared" ] || mem="$(cageworks_size_mib "$declared")" || return 1
	declared="$(printf '%s' "$declaration" | jq -r '.resources.journalQuota // empty')"
	[ -z "$declared" ] || journal="$(cageworks_size_mib "$declared")" || return 1

	printf '%s' "$declaration" | jq -c \
		--slurpfile local "$local_file" \
		--arg mem "$mem" \
		--arg journal "$journal" '
		. as $d
		| $local[0] as $l
		| { factory: $l.factory, system: $l.system, hostSystem: $l.hostSystem,
		    sshPort: $l.sshPort, authorizedKey: $l.authorizedKey,
		    declaration: $d }
		+ (if $d.resources.cores then { cpus: $d.resources.cores } else {} end)
		+ (if $mem == "" then {} else { mem: ($mem | tonumber) } end)
		+ (if $journal == "" then {} else { journalQuota: ($journal | tonumber) } end)
		+ (if $d.resources.egress then
		     { egress: $d.resources.egress
		     , egressHeaders:
		         ( ($l.credentials // {})
		         | with_entries(select(.key as $k | ($d.resources.egress | index($k)))) )
		     }
		   else {} end)'
}
