#!/usr/bin/env bash
## ADR-068's first two gates, which need the host's one Forgejo with two
## factories prepared on it and so cannot be a bats test: the owner of a
## factory's repository is an ordinary account that may do everything
## prepare does and nothing an admin does, and no account of one factory
## can see the other's repository.
##
## Wants a NixOS host whose services.fabriek declares two factories, named
## by A and B (default acme and widgets), each with at least one role, and
## a scratch directory. Both are brought up, because what is asked here is
## what prepare made.
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   A=acme B=widgets tests/manual/forge-boundary.sh
set -uo pipefail
A="${A:-acme}"
B="${B:-widgets}"
F="$A"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"
FACTS_DIR="${FABRIEK_FACTORIES:-/etc/fabriek/factories}"
[ -f "$FACTS_DIR/$B.env" ] || {
	echo "the factory $B is not declared on this host: no $FACTS_DIR/$B.env"
	exit 1
}
fact_of() { sed -n "s/^$2=//p" "$FACTS_DIR/$1.env"; }
## As root on this host with one named factory's facts loaded, the way
## lib.sh's onhost does it for the factory the proof is about; here either
## factory is asked, so the name is the first argument.
onhost_of() {
	local f="$1"
	shift
	## The host's own path first, as a unit has it: the forge's CLI there is
	## the wrapper that runs it as the forge's user, and a developer shell
	## carries the package itself, which refuses to run as root.
	sudo env "FABRIEK_FACTORY=$f" "FABRIEK_LIB=$FABRIEK_LIB" \
		"PATH=/run/current-system/sw/bin:$PATH" \
		bash -c "set -a; . '$FACTS_DIR/$f.env'; set +a; $*"
}
state_a="$(fact_of "$A" FABRIEK_STATE)"
state_b="$(fact_of "$B" FABRIEK_STATE)"
forge="http://$(fact_of "$A" FABRIEK_BRIDGE_HOST):$(fact_of "$A" FABRIEK_FORGEJO_PORT)/api/v1"

bash fabriek up "$A" || exit 1
bash fabriek up "$B" || exit 1

## One call as the holder of a token file on the host, printing the status
## alone or the body, as the caller asks. The token is read on the host and
## reaches curl in a header, never on this script's command line.
# shellcheck disable=SC2016  # the token expands on the host, not here
status_as() {
	local token="$1" method="$2" path="$3"
	sudo bash -c "curl -s -o /dev/null -w '%{http_code}' -X '$method' \
		-H \"Authorization: token \$(cat '$token')\" '$forge$path'" 2>/dev/null | tr -d '\r'
}
# shellcheck disable=SC2016
body_as() {
	local token="$1" method="$2" path="$3"
	sudo bash -c "curl -s -X '$method' -H \"Authorization: token \$(cat '$token')\" '$forge$path'" 2>/dev/null | tr -d '\r'
}

owner_a="$state_a/forge/operator-token"
owner_b="$state_b/forge/operator-token"
role_a="$(jq -r '.declaration.roles | keys[0]' "$(spec_json)")"
role_token_a="$state_a/forge/$role_a-token"

scenario "The owner is an ordinary account, and everything prepare does is the owner's"
given "the factory $A prepared by its own owner account $A-operator"
check "the repository is there, made by the owner" 200 "$(status_as "$owner_a" GET "/repos/$A-operator/$A")"
check "it is private" true "$(body_as "$owner_a" GET "/repos/$A-operator/$A" | jq -r .private)"
mapfile -t stages < <(jq -r '[.declaration.workflows[].stages[].needs] | unique | .[]' "$(spec_json)")
check "every stage of the workflow is a label the owner made" "$(printf '%s\n' "${stages[@]}" | sort | paste -sd, -)" \
	"$(body_as "$owner_a" GET "/repos/$A-operator/$A/labels" |
		jq -r --argjson s "$(printf '%s\n' "${stages[@]}" | jq -R . | jq -sc .)" '[.[].name | select(. as $n | $s | index($n))] | sort | join(",")')"
check "the role $role_a is a read collaborator, by the account it holds" read \
	"$(body_as "$owner_a" GET "/repos/$A-operator/$A/collaborators/$A-$role_a/permission" | jq -r .permission)"
when "the memory issue prepare opened as the role is read back"
check "it was posted by the role's own account" "$A-$role_a" \
	"$(body_as "$owner_a" GET "/repos/$A-operator/$A/issues?state=all&labels=memory&type=issues&limit=50" |
		jq -r --arg who "$A-$role_a" '.[] | select(.user.login == $who) | .user.login' | head -1)"
check "the owner labelled it memory" memory \
	"$(body_as "$owner_a" GET "/repos/$A-operator/$A/issues?state=all&labels=memory&type=issues&limit=50" |
		jq -r --arg who "$A-$role_a" '.[] | select(.user.login == $who) | [.labels[].name] | join(",")' | head -1)"
when "the owner asks the instance for its accounts"
check "the admin API refuses the owner" 403 "$(status_as "$owner_a" GET /admin/users)"
check "and refuses a role" 403 "$(status_as "$role_token_a" GET /admin/users)"

scenario "An account of one factory sees nothing of the other's"
given "$B's repository, private, owned by $B-operator"
check "$B's repository is there" 200 "$(status_as "$owner_b" GET "/repos/$B-operator/$B")"
when "$A's role asks for it"
## The forge answers 404 where the account cannot see the repository and
## 403 where the token's own scopes do not reach the endpoint; both are a
## refusal with nothing of the other factory in them, which is what the
## boundary is.
refused() { case "$1" in 403 | 404) echo refused ;; *) echo "$1" ;; esac; }
check "the repository is refused" refused "$(refused "$(status_as "$role_token_a" GET "/repos/$B-operator/$B")")"
check "its issues are refused" refused "$(refused "$(status_as "$role_token_a" GET "/repos/$B-operator/$B/issues")")"
when "$A's owner asks for it"
check "the repository answers 404, since the owner may ask and may not see" 404 \
	"$(status_as "$owner_a" GET "/repos/$B-operator/$B")"
when "$A's owner lists what it may reach"
check "it is $A's repository and nothing else" "$A-operator/$A" \
	"$(body_as "$owner_a" GET /user/repos | jq -r '[.[].full_name] | sort | join(",")')"

scenario "Two factories prepare against one database at the same time"
given "prepare, which is the whole of what speaks to the forge's CLI"
when "both factories prepare together, ten times over"
## The lock is the CLI's (ADR-068 point 5) and prepare is where every CLI
## call is, so this is the race asked for without ten renders of each
## factory. Each pair runs under the same per-factory locks up holds.
locked=0
prepare_log="$S/forge-concurrent.log"
: >"$prepare_log"
for _i in $(seq 1 10); do
	onhost_of "$A" "fabriek-container factory-prepare '$A'" >>"$prepare_log" 2>&1 &
	pid_a=$!
	onhost_of "$B" "fabriek-container factory-prepare '$B'" >>"$prepare_log" 2>&1 &
	pid_b=$!
	wait "$pid_a" || locked=1
	wait "$pid_b" || locked=1
	## Prepare restarts the factory's bus-acl unit, and systemd refuses a
	## unit started too often in a row; a pause between pairs keeps that
	## rate limit out of a measurement about the forge's database.
	sleep 12
done
check "every prepare succeeded" 0 "$locked"
check "no prepare met a locked database" 0 "$(grep -c 'database is locked' "$prepare_log")"
check "each account exists once" yes \
	"$(sudo /run/current-system/sw/bin/forgejo admin user list 2>/dev/null | awk 'NR > 1 { print $2 }' |
		sort | uniq -d | grep -q . && echo no || echo yes)"

scenario "One factory goes down and comes back to the board it had"
given "the board $A has, with its labels and its memory issues"
issues_before="$(body_as "$owner_a" GET "/repos/$A-operator/$A/issues?state=all&type=issues&limit=50" | jq -r 'length')"
labels_before="$(body_as "$owner_a" GET "/repos/$A-operator/$A/labels" | jq -r 'length')"
when "$A is brought down"
bash fabriek down "$A" >/dev/null 2>&1
check "$A's executor is inactive" inactive "$(systemctl is-active "fabriek-$A-executor" 2>/dev/null)"
check "$B's executor is still active" active "$(systemctl is-active "fabriek-$B-executor" 2>/dev/null)"
check "the forge is still serving" 200 "$(status_as "$owner_b" GET "/repos/$B-operator/$B")"
check "nothing deleted $A's repository" 200 "$(status_as "$owner_a" GET "/repos/$A-operator/$A")"
when "$A is brought up again"
bash fabriek up "$A" >/dev/null 2>&1
check "its issues are the ones it had" "$issues_before" \
	"$(body_as "$owner_a" GET "/repos/$A-operator/$A/issues?state=all&type=issues&limit=50" | jq -r 'length')"
check "its labels are the ones it had" "$labels_before" \
	"$(body_as "$owner_a" GET "/repos/$A-operator/$A/labels" | jq -r 'length')"

bash fabriek down "$B"
bash fabriek down "$A"
exit "$fail"
