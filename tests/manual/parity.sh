#!/usr/bin/env bash
## PRD-006's first success criterion: the journey of a goal from filed to
## mirrored with nothing typed after it, on a real machine. Written before
## anything on the machine can move a task (docs/roadmap.md 0.6), so that
## phase 5.1 has something to make pass; today it fails at the first Then,
## which says Forgejo is not on the machine.
##
## Wants the scratch directory the other proofs use: an operator config, a
## repository declaring a factory called acme whose workflow ship has stages
## needing design, build and test in that order, roles providing each, and an
## origin the machine can push to.
##
##   export CAGEWORKS_PROOF_DIR=/tmp/cageworks-proof
##   tests/manual/parity.sh
##
## What the machine must offer for these to pass, and where each is decided:
## Forgejo on the machine with an operator token under the state directory
## (2.3); a repository operator/<factory> whose labels are the workflow's
## stages (2.3); the executor and decider as units (3.3, 3.4);
## cageworks task file printing the issue number it opened (4.1);
## cageworks factory mirror pushing main and refs/cageworks/record (3.3).
set -uo pipefail
F=acme
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"
WAIT_TASK="${WAIT_TASK:-900}"

bash cageworks up "$F" || exit 1
wait_ssh || {
	echo "the machine never answered"
	exit 1
}

forge="http://localhost:3000/api/v1"
# shellcheck disable=SC2016  # the token expands on the machine, not here
api() {
	local method="$1" path="$2" body="${3:-}"
	sshm "curl -s -X '$method' -H 'Authorization: token \$(cat /var/lib/nixcage/forge/operator-token)' \
		-H 'Content-Type: application/json' ${body:+-d '$body'} '$forge$path'"
}
repo="/repos/operator/$F"
# shellcheck disable=SC2329  # invoked through eventually
labels_of() { api GET "$repo/issues/$1" | jq -r '[.labels[].name] | sort | join(",")'; }
# shellcheck disable=SC2329  # invoked through eventually
assignee_of() { api GET "$repo/issues/$1" | jq -r '.assignees[0].login // empty'; }
# shellcheck disable=SC2329  # invoked through eventually
outcome_count() { api GET "$repo/issues/$1/comments" | jq -r '[.[] | select(.body | test("^outcome:"))] | length'; }

scenario "The board is on the machine"
given "a factory whose machine is up"
when "the operator asks Forgejo for the factory's repository"
check "Forgejo answers" 200 "$(sshm "curl -s -o /dev/null -w '%{http_code}' $forge/version" 2>/dev/null)"
check "the repository operator/$F exists" 200 \
	"$(sshm "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: token \$(cat /var/lib/nixcage/forge/operator-token)' $forge$repo" 2>/dev/null)"
stages="$(jq -r '.workflows.ship.stages[].needs' "$D/spec.json" 2>/dev/null | paste -sd, -)"
check "the workflow ship declares design,build,test" "design,build,test" "$stages"
check "every stage is a label" "build,design,test" \
	"$(api GET "$repo/labels" | jq -r '[.[].name] | map(select(. == "design" or . == "build" or . == "test")) | sort | join(",")')"

scenario "A filed goal is assigned without a second command"
given "the executor and the decider are running"
check "the executor unit is active" active "$(sshm systemctl is-active cageworks-executor 2>/dev/null)"
check "the decider unit is active" active "$(sshm systemctl is-active cageworks-decider 2>/dev/null)"
when "the operator files a goal"
issue="$(bash cageworks task file "$F" ship --acceptance "the importer handles empty files" 2>/dev/null | tail -1)"
check "task file prints an issue number" yes "$([[ "$issue" =~ ^[0-9]+$ ]] && echo yes || echo no)"
check "the issue carries the design label" design "$(eventually 30 design labels_of "$issue")"
check "the issue is assigned to a role" yes \
	"$([ -n "$(eventually "$WAIT_TASK" x assignee_of "$issue" | head -c 1)" ] && echo yes || echo no)"

scenario "The work moves through every stage on its own"
given "the issue $issue at design"
when "the design role finishes"
check "an outcome comment appears" 1 "$(eventually "$WAIT_TASK" 1 outcome_count "$issue")"
check "the executor moves the issue to build" build "$(eventually 60 build labels_of "$issue")"
when "the build role finishes"
check "a second outcome appears" 2 "$(eventually "$WAIT_TASK" 2 outcome_count "$issue")"
check "the executor moves the issue to test" test "$(eventually 60 test labels_of "$issue")"
when "the test role finishes"
check "a third outcome appears" 3 "$(eventually "$WAIT_TASK" 3 outcome_count "$issue")"

scenario "The executor opens a pull request and nothing has left the machine"
# shellcheck disable=SC2329  # invoked through eventually
pr_count() { api GET "$repo/pulls?state=open" | jq -r 'length'; }
check "one pull request is open" 1 "$(eventually 120 1 pr_count)"
pr="$(api GET "$repo/pulls?state=open" | jq -r '.[0].number')"
head_branch="$(api GET "$repo/pulls/$pr" | jq -r '.head.ref')"
role="$(assignee_of "$issue")"
check "its branch is in the role's namespace" "$role" "${head_branch%%/*}"
origin="$(jq -r .repository "$D/spec.json")"
check "origin has no branch of that name yet" absent \
	"$(git ls-remote --heads "$origin" "$head_branch" 2>/dev/null | grep -q . && echo present || echo absent)"

scenario "The operator merges and mirrors, and the record travels"
given "the pull request $pr"
when "the operator merges it in Forgejo"
check "the merge is accepted" 200 \
	"$(sshm "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: token \$(cat /var/lib/nixcage/forge/operator-token)' -H 'Content-Type: application/json' -d '{\"Do\":\"merge\"}' $forge$repo/pulls/$pr/merge" 2>/dev/null)"
when "the operator runs cageworks factory mirror"
bash cageworks factory mirror "$F" >/dev/null 2>&1
main_forge="$(api GET "$repo/branches/main" | jq -r '.commit.id')"
main_origin="$(git ls-remote "$origin" refs/heads/main 2>/dev/null | cut -f1)"
check "origin's main is Forgejo's main" "$main_forge" "$main_origin"
check "origin carries refs/cageworks/record" present \
	"$(git ls-remote "$origin" refs/cageworks/record 2>/dev/null | grep -q . && echo present || echo absent)"

scenario "Spend was counted and the soft limit is the executor's"
given "the spend the proxy counted for this journey"
total="$(sshm "curl -s http://\$(jq -r .proxy /etc/cageworks/bridge.json)/status" | jq -r '[.[]] | add // 0')"
check "the proxy counted tokens" yes "$([ "${total:-0}" -gt 0 ] && echo yes || echo no)"
when "the operator reads the executor's routing state"
check "the executor is routing" routing "$(sshm cat /run/cageworks/executor/routing 2>/dev/null)"

bash cageworks down "$F"
exit "$fail"
