# shellcheck shell=bash
## fabriek up and down on the host (ADR-067): what the machine program does
## for one declared factory, as root, once the CLI has named it. Sourced by
## store path into fabriek-container beside operator-config.sh and
## credential.sh.
##
## The units of a factory, in the order they start; down stops them in
## reverse. The executor is apart: it starts on the prepared mark and is
## the first thing down stops.
fabriek_up_units() {
	local factory="$1" u
	for u in state bus bus-acl; do
		printf 'fabriek-%s-%s.service\n' "$factory" "$u"
	done
}

## The operator's prompts, skill files and catalogue directories, put in
## the store and rooted under the factory's directory (ADR-061 points 4
## and 6). A prompt or skill given as text stays text. Rewrites the config
## JSON in place with the store paths.
##
## fabriek_up_store_operator_files <roots-dir> <config.json>
fabriek_up_store_operator_files() {
	local dir="$1" json="$2" kind name value stored
	mkdir -p "$dir"
	local -a filters=()
	fabriek_up_fetch_git_catalogues "$dir" "$json" || return 1
	while IFS=$'\t' read -r kind name value; do
		[ -n "$value" ] || continue
		case "$kind:$value" in
		catalogue:*) ;;
		*:/*) ;;
		*) continue ;;
		esac
		stored="$(nix store add-path --name "${value##*/}" "$value")" || {
			echo "fabriek-container: could not add $value to the store" >&2
			return 1
		}
		nix-store --add-root "$dir/$kind-$name" --indirect -r "$stored" >/dev/null 2>&1 || true
		case "$kind" in
		specialist) filters+=(".specialists[$(jq -n --arg n "$name" '$n')].prompt = $(jq -n --arg s "$stored" '$s')") ;;
		skill) filters+=(".skills[$(jq -n --arg n "$name" '$n')].skill = $(jq -n --arg s "$stored" '$s')") ;;
		catalogue) filters+=(".catalogues |= map(if . == $(jq -n --arg v "$value" '$v') then $(jq -n --arg s "$stored" '$s') else . end)") ;;
		esac
	done < <(jq -r '
    ((.specialists // {}) | to_entries[] | select(.value.prompt) | "specialist\t\(.key)\t\(.value.prompt)"),
    ((.skills // {}) | to_entries[] | select(.value.skill) | "skill\t\(.key)\t\(.value.skill)"),
    ((.catalogues // []) | to_entries[] | select(.value | type == "string") | "catalogue\t\(.key)\t\(.value)")' "$json")
	[ ${#filters[@]} -gt 0 ] || return 0
	local program
	program="$(
		IFS='|'
		printf '%s' "${filters[*]}"
	)"
	jq "$program" "$json" >"$json.tmp" && mv "$json.tmp" "$json"
}

## A git catalogue (ADR-062 point 2): fetched by its rev, its tree's hash
## checked against the one the operator wrote, the dir found in it,
## rooted, and the entry rewritten with the store path beside what the
## operator wrote. Rewrites the config JSON in place.
##
## fabriek_up_fetch_git_catalogues <roots-dir> <config.json>
fabriek_up_fetch_git_catalogues() {
	local dir="$1" json="$2" index git rev want subdir stored got
	local -a filters=()
	## Fields split on a character no path carries: read on a tab folds
	## an empty narHash away and shifts the dir into its place.
	while IFS=$'\x1f' read -r index git rev want subdir; do
		[ -n "$git" ] || continue
		IFS=$'\t' read -r stored got < <(fabriek_catalogue_fetch "$git" "$rev" "$want" "$subdir") || true
		[ -n "$stored" ] || return 1
		nix-store --add-root "$dir/catalogue-$index" --indirect -r "${stored%%/"$subdir"}" >/dev/null 2>&1 || true
		filters+=(".catalogues[$index] += $(jq -cn --arg p "$stored" --arg h "$got" '{path: $p, narHash: $h}')")
	done < <(jq -r '(.catalogues // []) | to_entries[] | select(.value | type == "object")
    | [(.key | tostring), .value.git, .value.rev, (.value.narHash // ""), (.value.dir // "")] | join("\u001f")' "$json")
	[ ${#filters[@]} -gt 0 ] || return 0
	local program
	program="$(
		IFS='|'
		printf '%s' "${filters[*]}"
	)"
	jq "$program" "$json" >"$json.tmp" && mv "$json.tmp" "$json"
}

## The credential for this factory, written under its directory: the
## operator's config projected for it, plus the pin. The pin is the
## checkout's HEAD at the first up and moves only with --update, because
## which commit a factory works is its identity. The declaration is
## resolved and validated before anything is written, so a factory
## declared twice or declared wrong leaves nothing behind.
##
## fabriek_up_credential <factory> <etc-dir> <update-or-empty> <host-system>
## Prints the checkout's path.
fabriek_up_credential() {
	local factory="$1" etc="$2" update="$3" host_system="$4" config path rev
	config="$(fabriek_operator_config_path)"
	path="$(fabriek_operator_factory_path "$config" "$factory")" || return 1
	path="$(cd "$path" 2>/dev/null && pwd)" || {
		echo "fabriek-container: $factory's repository is not at the path the config names: $path" >&2
		return 1
	}
	local credential="$etc/fabriek.toml"
	if [ -f "$credential" ] && [ -z "$update" ]; then
		rev="$(fabriek_credential_rev "$credential")"
	else
		rev="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || {
			echo "fabriek-container: $factory's repository at $path has no commit to pin" >&2
			return 1
		}
	fi
	fabriek_declaration_resolve "$config" "$factory" "$path" "$rev" >/dev/null || return 1

	local json="$etc/config.json.new"
	fabriek_operator_config "$config" >"$json" || return 1
	fabriek_up_store_operator_files "$etc/roots" "$json" || {
		rm -f "$json"
		return 1
	}
	fabriek_credential_toml "$json" "$factory" "$path" "$rev" "$host_system" >"$credential.new" || {
		rm -f "$json"
		return 1
	}
	rm -f "$json"
	mv "$credential.new" "$credential"
	printf '%s\n' "$path"
}

## The model credentials the rendered factory reaches, filed under the
## factory's state for the proxy's user alone (ADR-025): a copy of the
## file the operator named, never its path in the credential and never a
## value on a command line. One for an endpoint the clamp dropped is not
## filed.
##
## fabriek_up_secrets <factory> <state-dir> <endpoints.json>
fabriek_up_secrets() {
	local factory="$1" state="$2" endpoints="$3" config creds host file
	[ -f "$endpoints" ] || return 0
	config="$(fabriek_operator_config_path)"
	creds="$(fabriek_operator_credentials "$config")" || return 1
	install -d -m 0700 "$state/egress"
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		file="$(printf '%s' "$creds" | jq -r --arg h "$host" '.[$h].file // empty')"
		if [ ! -f "$file" ]; then
			echo "fabriek-container: the credential for $host is not at $file" >&2
			return 1
		fi
		cp "$file" "$state/egress/$host"
		chmod 0400 "$state/egress/$host"
		chown fabriek-egress:fabriek-egress "$state/egress/$host" || return 1
	done < <(jq -r '.credentials | keys[]' "$endpoints")
	## The proxy read its headers when it started, which was before this.
	systemctl restart "fabriek-$factory-egress-credentials.service"
	systemctl reload-or-restart nginx.service
}
