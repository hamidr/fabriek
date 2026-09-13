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

## fabriek_machine_spec <declaration.json> <local.json>
##
## local.json carries factory, system, hostSystem, sshPort, authorizedKey, the
## operator's caps, and which header carries which endpoint's credential. The
## credential itself is never here: a spec is built, logged and written beside
## the machine, and a secret in one would be a secret in all three (ADR-025).
fabriek_machine_spec() {
	local declaration_file="$1" local_file="$2"
	local declaration caps

	declaration="$(fabriek_declaration_validate <"$declaration_file")" || return 1

	## What the clamp changed is kept in the spec rather than printed: this
	## runs inside a build, whose log the operator never sees when it
	## succeeds, and a dropped endpoint is something they must see.
	local caps notes
	caps="$(mktemp)"
	notes="$(mktemp)"
	jq '.caps // {}' "$local_file" >"$caps"
	declaration="$(printf '%s' "$declaration" | fabriek_resources_clamp "$caps" 2>"$notes")" || {
		cat "$notes" >&2
		rm -f "$caps" "$notes"
		return 1
	}
	rm -f "$caps"

	## Memory is declared the way a person writes it and a hypervisor counts
	## it in MiB, so it is converted here rather than anywhere a comparison
	## happens. The record's bound likewise (ADR-036): a machine told nothing
	## falls back to its own bound rather than to none.
	local mem="" record="" declared
	declared="$(printf '%s' "$declaration" | jq -r '.resources.memory // empty')"
	[ -z "$declared" ] || mem="$(fabriek_size_mib "$declared")" || return 1
	declared="$(printf '%s' "$declaration" | jq -r '.resources.recordQuota // empty')"
	[ -z "$declared" ] || record="$(fabriek_size_mib "$declared")" || return 1

	printf '%s' "$declaration" | jq -c \
		--slurpfile local "$local_file" \
		--rawfile notes "$notes" \
		--arg mem "$mem" \
		--arg record "$record" '
		. as $d
		| $local[0] as $l
		| { factory: $l.factory, system: $l.system, hostSystem: $l.hostSystem,
		    sshPort: $l.sshPort, authorizedKey: $l.authorizedKey,
		    declaration: $d,
		    notes: ($notes | split("\n") | map(select(. != ""))) }
		+ (if $d.resources.cores then { cpus: $d.resources.cores } else {} end)
		+ (if $mem == "" then {} else { mem: ($mem | tonumber) } end)
		+ (if $record == "" then {} else { recordQuota: ($record | tonumber) } end)
		+ (if $d.resources.tokens then { tokenCeiling: $d.resources.tokens } else {} end)
		+ (if $d.resources.egress then
		     { egress: $d.resources.egress
		     , egressHeaders:
		         ( ($l.credentials // {})
		         | with_entries(select(.key as $k | ($d.resources.egress | index($k)))) )
		     }
		   else {} end)'
	rm -f "$notes"
}
