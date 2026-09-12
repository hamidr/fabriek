# shellcheck shell=bash
## The forge on the machine, prepared and prepared again (ADR-036).
##
## Everything here is made only if it is absent, so that cageworks up after
## a rebuild is the same command as the first one. Tokens are minted once and
## kept as files under the state directory, readable by root alone, and reach
## the API through a header file rather than an argument: an argument is
## readable from /proc by anything on the machine.
##
## Sourced by store path into cageworks-container beside names.sh. A file
## rather than an inline string so shellcheck reads it and bats sources it,
## with the forge's CLI and curl stubbed on PATH.

## Where the forge's tokens live. Beside the bus passwords, and for the same
## reason: the pool outlives a rebuild and a token minted twice is two tokens.
cageworks_forge_dir() { printf '%s/forge\n' "$1"; }
cageworks_forge_token_path() {
	local state="$1" who="$2"
	cageworks_name_ok "$who" || return 1
	printf '%s/%s-token\n' "$(cageworks_forge_dir "$state")" "$who"
}

## The forge's own CLI, run as its user, which is the only way an account is
## made when registration is off.
cageworks_forge_admin() {
	forgejo admin "$@"
}

cageworks_forge_user_exists() {
	local who="$1"
	cageworks_forge_admin user list 2>/dev/null | grep -qE "(^| )$who( |$)"
}

## An account, once. A role's password is random and never kept: nothing logs
## in as a role, only its token does.
cageworks_forge_ensure_user() {
	local who="$1" email="$2"
	shift 2
	cageworks_forge_user_exists "$who" && return 0
	cageworks_forge_admin user create "$@" --username "$who" \
		--password "$(cageworks_secret)" --email "$email" \
		--must-change-password=false >/dev/null
}

## A token, once, with exactly the scopes the caller names, kept as a file.
cageworks_forge_ensure_token() {
	local state="$1" who="$2" scopes="$3" file
	file="$(cageworks_forge_token_path "$state" "$who")" || return 1
	[ -s "$file" ] && return 0
	mkdir -p "$(dirname "$file")"
	chmod 0700 "$(dirname "$file")"
	local token
	token="$(cageworks_forge_admin user generate-access-token \
		--username "$who" --token-name cageworks --scopes "$scopes" --raw)" || return 1
	(umask 077 && printf '%s\n' "$token" >"$file.new") && mv "$file.new" "$file"
	chmod 0400 "$file"
}

## A random secret: a password nothing needs to remember, or a bus password
## the ACL is set from.
cageworks_secret() {
	head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40
	echo
}

## One API call, as the holder of a token file. The token reaches curl as a
## header read from a file, so it is in no argument and no log line.
##
## cageworks_forge_api <base-url> <token-file> <method> <path> [json-body]
cageworks_forge_api() {
	local base="$1" token_file="$2" method="$3" path="$4" body="${5:-}"
	local header
	header="$(mktemp)"
	printf 'Authorization: token %s\n' "$(cat "$token_file")" >"$header"
	local -a args=(-s -f -X "$method" -H "@$header" -H 'Content-Type: application/json')
	[ -n "$body" ] && args+=(-d "$body")
	local status=0
	curl "${args[@]}" "$base$path" || status=$?
	rm -f "$header"
	return "$status"
}

## The repository the board lives in, once. Private, because its issues are
## the record and its branches are a role's work in progress.
cageworks_forge_ensure_repository() {
	local base="$1" token="$2" owner="$3" name="$4"
	cageworks_forge_api "$base" "$token" GET "/repos/$owner/$name" >/dev/null 2>&1 && return 0
	cageworks_forge_api "$base" "$token" POST /user/repos \
		"$(jq -cn --arg n "$name" '{name: $n, private: true, auto_init: false}')" >/dev/null
}

## Read on the repository, for a role. Idempotent on the forge's side.
cageworks_forge_ensure_reader() {
	local base="$1" token="$2" owner="$3" name="$4" who="$5"
	cageworks_forge_api "$base" "$token" PUT "/repos/$owner/$name/collaborators/$who" \
		'{"permission":"read"}' >/dev/null
}

## A label, once. The stage labels are the executor's to move (ADR-036 point
## 1) and blocked and memory are the two others the design names.
cageworks_forge_ensure_label() {
	local base="$1" token="$2" owner="$3" name="$4" label="$5" existing
	existing="$(cageworks_forge_api "$base" "$token" GET "/repos/$owner/$name/labels" |
		jq -r '.[].name')"
	printf '%s\n' "$existing" | grep -qxF "$label" && return 0
	cageworks_forge_api "$base" "$token" POST "/repos/$owner/$name/labels" \
		"$(jq -cn --arg l "$label" '{name: $l, color: "#888888"}')" >/dev/null
}

## A role's memory issue, once, opened as the role so that the role is its
## poster and may rewrite it and nobody else may (ADR-036 point 3). Labelled
## and pinned by the operator's token, because a role's cannot label.
cageworks_forge_ensure_memory() {
	local base="$1" operator="$2" role_token="$3" owner="$4" name="$5" role="$6"
	local number
	number="$(cageworks_forge_api "$base" "$operator" GET \
		"/repos/$owner/$name/issues?state=all&labels=memory&type=issues&limit=50" |
		jq -r --arg r "$role" '.[] | select(.user.login == $r) | .number' | head -1)"
	[ -n "$number" ] && return 0
	number="$(cageworks_forge_api "$base" "$role_token" POST "/repos/$owner/$name/issues" \
		"$(jq -cn --arg t "memory: $role" '{title: $t, body: ""}')" | jq -r .number)" || return 1
	[ -n "$number" ] || return 1
	local label_id
	label_id="$(cageworks_forge_api "$base" "$operator" GET "/repos/$owner/$name/labels" |
		jq -r '.[] | select(.name == "memory") | .id' | head -1)"
	cageworks_forge_api "$base" "$operator" POST "/repos/$owner/$name/issues/$number/labels" \
		"$(jq -cn --argjson id "${label_id:-0}" '{labels: [$id]}')" >/dev/null
	cageworks_forge_api "$base" "$operator" POST "/repos/$owner/$name/issues/$number/pin" >/dev/null || true
}
