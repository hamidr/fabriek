# shellcheck shell=bash
## The forge on the machine, prepared and prepared again (ADR-036).
##
## Everything here is made only if it is absent, so that fabriek up after
## a rebuild is the same command as the first one. Tokens are minted once and
## kept as files under the state directory, readable by root alone, and reach
## the API through a header file rather than an argument: an argument is
## readable from /proc by anything on the machine.
##
## Sourced by store path into fabriek-container beside names.sh. A file
## rather than an inline string so shellcheck reads it and bats sources it,
## with the forge's CLI and curl stubbed on PATH.

## Where the forge's tokens live. Beside the bus passwords, and for the same
## reason: the pool outlives a rebuild and a token minted twice is two tokens.
fabriek_forge_dir() { printf '%s/forge\n' "$1"; }
fabriek_forge_token_path() {
	local state="$1" who="$2"
	fabriek_name_ok "$who" || return 1
	printf '%s/%s-token\n' "$(fabriek_forge_dir "$state")" "$who"
}

## The account a factory holds on the host's forge (ADR-068 point 4): one
## Forgejo serves every factory, so the name carries the factory as the
## role's cage and its bus user already do. The token file keeps the bare
## name, since a factory's state holds only its own.
fabriek_forge_account() {
	local factory="$1" who="$2"
	fabriek_name_ok "$factory" || return 1
	fabriek_name_ok "$who" || return 1
	printf '%s-%s\n' "$factory" "$who"
}

## Where the forge keeps its state, and the lock beside it. One Forgejo
## serves every factory (ADR-068 point 1) and the host names its dataset in
## every factory's facts file; the default is that same path, for a hand
## running the program with no facts loaded.
fabriek_forge_state() {
	printf '%s\n' "${FABRIEK_FORGE_STATE:-/var/lib/nixcage/fabriek-forge}"
}
fabriek_forge_lock_path() {
	printf '%s/cli.lock\n' "$(fabriek_forge_state)"
}

## The forge's own CLI, run as its user, which is the only way an account is
## made when registration is off.
##
## Under the host's lock, held for the call (ADR-068 point 5): the CLI opens
## the sqlite database beside the running server, and two factories prepare
## under locks of their own, so without this one their CLI calls meet on one
## database. The API needs none; the server serialises what reaches it.
fabriek_forge_admin() {
	local lock
	lock="$(fabriek_forge_lock_path)"
	mkdir -p "$(dirname "$lock")"
	flock "$lock" forgejo admin "$@"
}

fabriek_forge_user_exists() {
	local who="$1"
	fabriek_forge_admin user list 2>/dev/null | grep -qE "(^| )$who( |$)"
}

## An account, once. A role's password is random and never kept: nothing logs
## in as a role, only its token does.
##
## The CLI opens the database beside the running server and can lose that
## race, so a list that shows nothing is not proof of absence: a create that
## finds the account there is the confirmation, not an error.
fabriek_forge_ensure_user() {
	local who="$1" email="$2"
	shift 2
	fabriek_forge_user_exists "$who" && return 0
	local err
	if err="$(fabriek_forge_admin user create "$@" --username "$who" \
		--password "$(fabriek_secret)" --email "$email" \
		--must-change-password=false 2>&1 >/dev/null)"; then
		return 0
	fi
	case "$err" in
	*"user already exists"*) return 0 ;;
	esac
	printf '%s\n' "$err" >&2
	return 1
}

## A token, once, with exactly the scopes the caller names, kept as a file.
## The file is keyed by the bare name and the token is the account's: a
## factory's state holds only its own tokens, and the account it belongs to
## is the forge's business (ADR-068 point 4).
##
## fabriek_forge_ensure_token <state> <key> <account> <scopes>
fabriek_forge_ensure_token() {
	local state="$1" who="$2" account="$3" scopes="$4" file
	file="$(fabriek_forge_token_path "$state" "$who")" || return 1
	[ -s "$file" ] && return 0
	mkdir -p "$(dirname "$file")"
	chmod 0700 "$(dirname "$file")"
	local token
	token="$(fabriek_forge_mint_token "$account" "$scopes")" || return 1
	(umask 077 && printf '%s\n' "$token" >"$file.new") && mv "$file.new" "$file"
	chmod 0400 "$file"
}

## One token for an account, printed. Named fabriek, and when that name is
## taken under a name of its own: the forge has no way to delete an access
## token, so a name an account has used is used for good, and a token whose
## file is gone is unreachable rather than reusable. Any other refusal is
## the caller's failure and is said in the forge's own words.
fabriek_forge_mint_token() {
	local account="$1" scopes="$2" err token status=0
	err="$(mktemp)"
	token="$(fabriek_forge_admin user generate-access-token \
		--username "$account" --token-name fabriek --scopes "$scopes" --raw 2>"$err")" || status=$?
	if [ "$status" != 0 ]; then
		if grep -q 'access token name has been used already' "$err"; then
			status=0
			token="$(fabriek_forge_admin user generate-access-token \
				--username "$account" --token-name "fabriek-$(date +%s)" \
				--scopes "$scopes" --raw 2>"$err")" || status=$?
		fi
	fi
	[ "$status" = 0 ] || cat "$err" >&2
	rm -f "$err"
	[ "$status" = 0 ] || return "$status"
	printf '%s\n' "$token"
}

## A token file the forge no longer honours is not a token, and keeping it
## makes prepare fail at the first call that needs one. It happens when the
## account it belongs to is gone with the instance that held it (ADR-068
## put every factory on one Forgejo, where each had its own before), and
## when a token is revoked in the UI. Dropped here so the ensure that
## follows mints one; a forge that cannot be reached at all leaves the file
## where it is, since that is not an answer about the token.
##
## The path is the caller's, because a token may ask only what its scopes
## allow: the owner's reaches /user, and a role's issue-scoped one reaches
## its repository's issues and not /user.
##
## fabriek_forge_drop_stale_token <base> <state> <key> <path>
fabriek_forge_drop_stale_token() {
	local base="$1" state="$2" who="$3" path="$4" file status=0
	file="$(fabriek_forge_token_path "$state" "$who")" || return 1
	[ -s "$file" ] || return 0
	fabriek_forge_api "$base" "$file" GET "$path" >/dev/null 2>&1 || status=$?
	## 22 is curl's word for a status the server refused with; anything
	## else is the forge not answering.
	[ "$status" = 22 ] || return 0
	rm -f "$file"
}

## A random secret: a password nothing needs to remember, or a bus password
## the ACL is set from.
fabriek_secret() {
	head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40
	echo
}

## One API call, as the holder of a token file. The token reaches curl as a
## header read from a file, so it is in no argument and no log line.
##
## fabriek_forge_api <base-url> <token-file> <method> <path> [json-body]
fabriek_forge_api() {
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
fabriek_forge_ensure_repository() {
	local base="$1" token="$2" owner="$3" name="$4"
	fabriek_forge_api "$base" "$token" GET "/repos/$owner/$name" >/dev/null 2>&1 && return 0
	fabriek_forge_api "$base" "$token" POST /user/repos \
		"$(jq -cn --arg n "$name" '{name: $n, private: true, auto_init: false}')" >/dev/null
}

## Read on the repository, for a role. Idempotent on the forge's side.
fabriek_forge_ensure_reader() {
	local base="$1" token="$2" owner="$3" name="$4" who="$5"
	fabriek_forge_api "$base" "$token" PUT "/repos/$owner/$name/collaborators/$who" \
		'{"permission":"read"}' >/dev/null
}

## A label, once. The stage labels are the executor's to move (ADR-036 point
## 1) and blocked and memory are the two others the design names.
fabriek_forge_ensure_label() {
	local base="$1" token="$2" owner="$3" name="$4" label="$5" existing
	existing="$(fabriek_forge_api "$base" "$token" GET "/repos/$owner/$name/labels" |
		jq -r '.[].name')"
	printf '%s\n' "$existing" | grep -qxF "$label" && return 0
	fabriek_forge_api "$base" "$token" POST "/repos/$owner/$name/labels" \
		"$(jq -cn --arg l "$label" '{name: $l, color: "#888888"}')" >/dev/null
}

## A role's memory issue, once, opened as the role so that the role is its
## poster and may rewrite it and nobody else may (ADR-036 point 3). Labelled
## and pinned by the operator's token, because a role's cannot label.
fabriek_forge_ensure_memory() {
	local base="$1" operator="$2" role_token="$3" owner="$4" name="$5" role="$6" account="$7"
	local number
	number="$(fabriek_forge_api "$base" "$operator" GET \
		"/repos/$owner/$name/issues?state=all&labels=memory&type=issues&limit=50" |
		jq -r --arg r "$account" '.[] | select(.user.login == $r) | .number' | head -1)"
	[ -n "$number" ] && return 0
	number="$(fabriek_forge_api "$base" "$role_token" POST "/repos/$owner/$name/issues" \
		"$(jq -cn --arg t "memory: $role" '{title: $t, body: ""}')" | jq -r .number)" || return 1
	[ -n "$number" ] || return 1
	local label_id
	label_id="$(fabriek_forge_api "$base" "$operator" GET "/repos/$owner/$name/labels" |
		jq -r '.[] | select(.name == "memory") | .id' | head -1)"
	fabriek_forge_api "$base" "$operator" POST "/repos/$owner/$name/issues/$number/labels" \
		"$(jq -cn --argjson id "${label_id:-0}" '{labels: [$id]}')" >/dev/null
	fabriek_forge_api "$base" "$operator" POST "/repos/$owner/$name/issues/$number/pin" >/dev/null || true
}

## The record as origin holds it: issues.json on refs/fabriek/record, what
## mirror exported (ADR-036 point 7). Fetched into a repository made for the
## purpose, because prepare runs before the factory's clone need exist.
## Prints nothing when origin carries no record; fails only when origin
## cannot be asked at all.
fabriek_record_read() {
	local origin="$1" tmp
	tmp="$(mktemp -d)"
	local status=0
	if git init -q "$tmp" &&
		GIT_TERMINAL_PROMPT=0 git -C "$tmp" fetch -q --depth 1 "$origin" refs/fabriek/record 2>/dev/null; then
		git -C "$tmp" show FETCH_HEAD:issues.json || status=1
	elif ! GIT_TERMINAL_PROMPT=0 git ls-remote -q "$origin" >/dev/null 2>&1; then
		status=1
	fi
	rm -rf "$tmp"
	return "$status"
}

## The record's issues, opened again on a board that has none. In number
## order, so that what was filed first is filed first again; the numbers
## themselves are the forge's and are not promised. Memory issues are left
## out, because each is opened as its role and prepare does that itself.
## A label the declaration no longer has is named and dropped, and the
## issue keeps the rest; the record is not edited to fit.
fabriek_forge_restore_record() {
	local base="$1" token="$2" owner="$3" name="$4" record="$5"
	local labels number issue title body state wanted ids unknown
	labels="$(fabriek_forge_api "$base" "$token" GET "/repos/$owner/$name/labels")" || return 1
	while IFS= read -r issue; do
		[ -n "$issue" ] || continue
		title="$(jq -r '.title' <<<"$issue")"
		body="$(jq -r '.body // ""' <<<"$issue")"
		state="$(jq -r '.state' <<<"$issue")"
		number="$(fabriek_forge_api "$base" "$token" POST "/repos/$owner/$name/issues" \
			"$(jq -cn --arg t "$title" --arg b "$body" '{title: $t, body: $b}')" | jq -r .number)" || return 1
		[ -n "$number" ] || return 1
		wanted="$(jq -c '[.labels[].name]' <<<"$issue")"
		ids="$(jq -c --argjson w "$wanted" '[.[] | select(.name as $n | $w | index($n)) | .id]' <<<"$labels")"
		unknown="$(jq -r --argjson w "$wanted" '[.[].name] as $have | $w[] | . as $l | select(($have | index($l)) == null)' <<<"$labels")"
		[ -z "$unknown" ] || printf 'fabriek: the record labels "%s" with %s, which the declaration no longer has\n' \
			"$title" "$(paste -sd, - <<<"$unknown")" >&2
		if [ "$ids" != "[]" ]; then
			fabriek_forge_api "$base" "$token" POST "/repos/$owner/$name/issues/$number/labels" \
				"$(jq -cn --argjson l "$ids" '{labels: $l}')" >/dev/null || return 1
		fi
		if [ "$state" = "closed" ]; then
			fabriek_forge_api "$base" "$token" PATCH "/repos/$owner/$name/issues/$number" \
				'{"state":"closed"}' >/dev/null || return 1
		fi
	done < <(jq -c 'sort_by(.number) | .[] | select(([.labels[].name] | index("memory")) == null)' <<<"$record")
}

## Whether the board has any issue at all, memory ones included.
fabriek_forge_board_empty() {
	local base="$1" token="$2" owner="$3" name="$4"
	[ "$(fabriek_forge_api "$base" "$token" GET "/repos/$owner/$name/issues?state=all&type=issues&limit=1" |
		jq -r 'length')" = "0" ]
}

## Where the forge's copy of the repository is pushed to and fetched from,
## for the executor and for prepare alike. Overridable for a suite that has
## no forge listening, so a push lands in a bare repository of its own.
fabriek_forge_git_url() {
	local plan="$1" owner="$2" name="$3"
	if [ -n "${FABRIEK_FORGE_GIT_URL:-}" ]; then
		printf '%s\n' "$FABRIEK_FORGE_GIT_URL"
	else
		printf 'http://%s/%s/%s.git\n' "$(jq -r .forgejo "$plan")" "$owner" "$name"
	fi
}

## main on the forge, once (ADR-036 points 5 and 7): a role's pull request
## and the operator's mirror both need it there, and the forge's copy starts
## empty. Pushed from a clone of origin made for the purpose, with the
## operator's token through a credential helper that reads the file, so the
## token is in no argument and no remote URL. The origin is the operator's
## checkout and this runs as root, so the clone names it safe the way the
## factory's own clone does (fabriek_factory_git_args, factory-clone.sh,
## sourced beside this).
##
## fabriek_forge_ensure_main <base> <token-file> <owner> <name> <origin> <git-url>
fabriek_forge_ensure_main() {
	local base="$1" token="$2" owner="$3" name="$4" origin="$5" url="$6"
	fabriek_forge_api "$base" "$token" GET "/repos/$owner/$name/branches/main" >/dev/null 2>&1 && return 0
	local tmp status=0
	tmp="$(mktemp -d)"
	local -a git_args=()
	local arg
	while IFS= read -r arg; do
		git_args+=("$arg")
	done < <(fabriek_factory_git_args "$origin")
	## git's own words are kept: what went wrong is what the log should say.
	if GIT_TERMINAL_PROMPT=0 git "${git_args[@]}" clone -q --bare --branch main --single-branch "$origin" "$tmp/origin.git"; then
		local attempt
		for attempt in 1 2 3 4 5; do
			status=0
			GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper \
				GIT_CONFIG_VALUE_0="!f() { echo username=$owner; echo \"password=\$(cat '$token')\"; }; f" \
				git -C "$tmp/origin.git" push -q "$url" refs/heads/main:refs/heads/main && break
			status=1
			echo "fabriek: push of main to the forge failed on attempt $attempt" >&2
			sleep 2
		done
	else
		status=1
	fi
	rm -rf "$tmp"
	return "$status"
}
