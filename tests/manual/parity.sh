#!/usr/bin/env bash
## PRD-006's first success criterion: the journey of a goal from filed to
## mirrored with nothing typed after it, on a real machine. Written before
## anything on the machine can move a task (docs/roadmap.md 0.6), so that
## phase 5.1 has something to make pass; today it fails at the first Then,
## which says Forgejo is not on the machine.
##
## Wants the scratch directory the other proofs use: an operator config, a
## repository declaring a factory called acme with a workflow called ship,
## a role providing each of its stages, an origin the machine can push to,
## and a credential the allowed endpoint accepts. Without the last the
## journey stops at the first assignment, and the proof says so rather than
## failing: a decider with no model decides nothing.
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   F=acme tests/manual/parity.sh
##
## The goal and its acceptance are GOAL and ACCEPTANCE. A role's branch
## keeps what it built across runs, and done counts only commits made for
## the attempt, so a run after one that delivered the default goal needs
## a goal the repository has not met yet:
##
##   GOAL="the importer drops a byte order mark" \
##   ACCEPTANCE="a UTF-8 BOM before the first cell is not part of it" \
##   F=acme tests/manual/parity.sh
##
## What the machine must offer for these to pass, and where each is decided:
## Forgejo on the machine with an operator token under the state directory
## (2.3); a repository <factory>-operator/<factory> whose labels are the
## workflow's stages (2.3); the executor as a unit and the decider as a session it
## starts (3.3, 3.4); fabriek task file printing the issue number it
## opened (4.1); fabriek factory mirror pushing main and
## refs/fabriek/record (3.3).
set -uo pipefail
F="${F:-acme}"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"
WAIT_TASK="${WAIT_TASK:-900}"

bash fabriek up "$F" || exit 1

plan="$(onhost "cat '$ETC/bridge.json'" 2>/dev/null)"
forge="http://$(jq -r .forgejo <<<"$plan")/api/v1"
proxy="$(jq -r .proxy <<<"$plan")"
# shellcheck disable=SC2016  # the token expands on the machine, not here
api() {
	local method="$1" path="$2" body="${3:-}"
	onhost "curl -s -X '$method' -H \"Authorization: token \$(cat $STATE/forge/operator-token)\" \
		-H 'Content-Type: application/json' ${body:+-d '$body'} '$forge$path'"
}
repo="/repos/$F-operator/$F"
# shellcheck disable=SC2329  # invoked through eventually
labels_of() { api GET "$repo/issues/$1" | jq -r '[.labels[].name] | sort | join(",")'; }
# shellcheck disable=SC2329  # invoked through eventually
assignee_of() { api GET "$repo/issues/$1" | jq -r '.assignees[0].login // empty'; }
# shellcheck disable=SC2329  # invoked through eventually
outcome_count() { api GET "$repo/issues/$1/comments" | jq -r '[.[] | select(.body | test("^outcome:"))] | length'; }
# shellcheck disable=SC2329  # invoked through eventually
state_of() { api GET "$repo/issues/$1" | jq -r '.state'; }

scenario "The board is on the machine"
given "a factory whose machine is up"
when "the operator asks Forgejo for the factory's repository"
check "Forgejo answers" 200 "$(onhost "curl -s -o /dev/null -w '%{http_code}' $forge/version" 2>/dev/null)"
check "the repository $F-operator/$F exists" 200 \
	"$(onhost "curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: token \$(cat $STATE/forge/operator-token)\" $forge$repo" 2>/dev/null)"
mapfile -t stages < <(jq -r '.declaration.workflows.ship.stages[].needs' "$(spec_json)" 2>/dev/null)
check "the workflow ship declares at least two stages" yes "$([ "${#stages[@]}" -ge 2 ] && echo yes || echo no)"
check "every stage is a label" "$(printf '%s\n' "${stages[@]}" | sort | paste -sd, -)" \
	"$(api GET "$repo/labels" | jq -r --argjson s "$(printf '%s\n' "${stages[@]}" | jq -R . | jq -sc .)" '[.[].name | select(. as $n | $s | index($n))] | sort | join(",")')"

scenario "A filed goal is assigned without a second command"
given "the executor is running and the decider's session with it"
check "the executor unit is active" active "$(systemctl is-active "fabriek-$F-executor" 2>/dev/null)"
## up returns before the executor has started its sessions (seen
## 2026-09-22: the decider asked for a few seconds too early), so its cage
## is waited for, as isolation.sh waits for the roles'.
# shellcheck disable=SC2329  # invoked through eventually
decider_running() { cage_verb status "'$F-decider'" 2>/dev/null | grep -q '^running' && echo yes || echo no; }
check "the decider's cage is running" yes "$(eventually 60 yes decider_running)"
when "the operator files a goal"
## Filing is one entry on the operator stream; the executor opens the issue.
## The number is read off the board by title, because task file cannot know
## it before the executor has acted.
title="${GOAL:-the importer handles empty files} $(date +%s)"
check "task file is accepted" "$F: filed at ${stages[0]}" "$(bash fabriek -f "$F" file ship "$title" -m "acceptance: ${ACCEPTANCE:-an empty file imports as no rows}" 2>/dev/null | tail -1)"
# shellcheck disable=SC2329  # invoked through eventually
issue_by_title() { api GET "$repo/issues?state=all&type=issues&limit=50" | jq -r --arg t "$title" '.[] | select(.title == $t) | .number' | head -1 | sed 's/^[0-9][0-9]*$/found/'; }
check "the executor opens an issue for it" found "$(eventually 60 found issue_by_title)"
issue="$(api GET "$repo/issues?state=all&type=issues&limit=50" | jq -r --arg t "$title" '.[] | select(.title == $t) | .number' | head -1)"
check "the issue carries the first stage's label" "${stages[0]}" "$(eventually 30 "${stages[0]}" labels_of "$issue")"

## Everything from here needs a model to answer: the decider assigns and a
## role works only through the proxy, and the proxy only relays what the
## endpoint accepts. Asked once, from the machine, before waiting on it.
answer="$(onhost "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
	-d '{\"model\":\"probe\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' \
	http://$proxy/$(jq -r '.egress[0]' "$(spec_json)")/v1/messages" 2>/dev/null | tr -d '\r')"
if [ "$answer" = 401 ]; then
	gated "the issue is assigned to a role" "the endpoint refused the credential, and a decider with no model decides nothing; needs a real one"
	gated "the work moves through every stage on its own" "same"
	gated "the executor opens a pull request and the operator merges and mirrors" "same"
	gated "spend was counted" "same"
	bash fabriek down "$F"
	exit "$fail"
fi
## Waited for as yes or no, not as a name it could never equal: the old
## form waited the whole WAIT_TASK before it looked (seen 2026-09-22).
# shellcheck disable=SC2329  # invoked through eventually
assigned() { [ -n "$(assignee_of "$issue")" ] && echo yes || echo no; }
check "the issue is assigned to a role" yes "$(eventually "$WAIT_TASK" yes assigned)"

scenario "The work moves through every stage on its own"
given "the issue $issue at ${stages[0]}"
n=0
for stage in "${stages[@]}"; do
	n=$((n + 1))
	when "the $stage role finishes"
	check "outcome $n appears" "$n" "$(eventually "$WAIT_TASK" "$n" outcome_count "$issue")"
	if [ "$n" -lt "${#stages[@]}" ]; then
		check "the executor moves the issue to ${stages[$n]}" "${stages[$n]}" "$(eventually 60 "${stages[$n]}" labels_of "$issue")"
	else
		check "the executor closes the issue after the last stage" closed "$(eventually 60 closed state_of "$issue")"
	fi
done

scenario "The executor opens a pull request, and the operator sees the branch in their checkout and nowhere else"
# shellcheck disable=SC2329  # invoked through eventually
## At least one: the decider may push more than the builder's branch, and
## which roles it pushes is its judgment, not this proof's (seen
## 2026-09-22: the architect's and the manager's beside the builder's).
## The newest is the one the last stage's work is on.
pr_open() { [ "$(api GET "$repo/pulls?state=open" | jq -r 'length')" -ge 1 ] && echo yes || echo no; }
check "a pull request is open" yes "$(eventually 120 yes pr_open)"
pr="$(api GET "$repo/pulls?state=open" | jq -r 'max_by(.number) | .number')"
head_branch="$(api GET "$repo/pulls/$pr" | jq -r '.head.ref')"
check "its branch is in a role's namespace" yes "$(printf '%s\n' "${head_branch%%/*}" | grep -qxF -f <(jq -r '.declaration.roles | keys[]' "$(spec_json)") && echo yes || echo no)"
## The origin is the operator's checkout on this host (ADR-067 point 5):
## the branch reaches it by the operator's own fetch under the factory's
## name, and its own branch and tree stay as they were.
origin="$(onhost "cat '$STATE/origin'" 2>/dev/null)"
checkout_head="$(git -C "$origin" rev-parse HEAD)"
checkout_status="$(git -C "$origin" status --porcelain)"
bash fabriek -f "$F" fetch >/dev/null 2>&1
check "the checkout carries the branch under fabriek/$F/" present \
	"$(git -C "$origin" rev-parse --verify --quiet "refs/heads/fabriek/$F/$head_branch" >/dev/null && echo present || echo absent)"
check "the checkout has no branch of that bare name" absent \
	"$(git -C "$origin" rev-parse --verify --quiet "refs/heads/$head_branch" >/dev/null && echo present || echo absent)"

scenario "The operator merges and mirrors, and the record travels into the checkout"
given "the pull request $pr"
when "the operator merges it in Forgejo"
check "the merge is accepted" 200 \
	"$(onhost "curl -s -o /dev/null -w '%{http_code}' -X POST -H \"Authorization: token \$(cat $STATE/forge/operator-token)\" -H 'Content-Type: application/json' -d '{\"Do\":\"merge\"}' $forge$repo/pulls/$pr/merge" 2>/dev/null)"
when "the operator runs fabriek mirror"
bash fabriek -f "$F" mirror >/dev/null 2>&1
main_forge="$(api GET "$repo/branches/main" | jq -r '.commit.id')"
## mirror is asked on the bus and answered by the executor when it next
## comes round, and the checkout is the operator's own fetch after that
## (ADR-067 point 5), so both are waited for rather than read at once.
# shellcheck disable=SC2329  # invoked through eventually
fetched_main() {
	bash fabriek -f "$F" fetch >/dev/null 2>&1
	git -C "$origin" rev-parse --verify --quiet "refs/heads/fabriek/$F/main"
}
main_checkout="$(eventually 120 "$main_forge" fetched_main)"
check "the checkout's fabriek/$F/main is Forgejo's main" "$main_forge" "$main_checkout"
check "the checkout carries refs/fabriek/$F/record" present \
	"$(git -C "$origin" rev-parse --verify --quiet "refs/fabriek/$F/record" >/dev/null && echo present || echo absent)"
check "the checkout's own branch has not moved" "$checkout_head" "$(git -C "$origin" rev-parse HEAD)"
check "the checkout's working tree is as the operator left it" "$checkout_status" "$(git -C "$origin" status --porcelain)"

scenario "Spend was counted and the soft limit is the executor's"
given "the spend the proxy counted for this journey"
total="$(onhost "curl -s http://$proxy/status" | jq -r '[.[]] | add // 0')"
check "the proxy counted tokens" yes "$([ "${total:-0}" -gt 0 ] && echo yes || echo no)"
when "the operator reads the executor's board on the relay"
check "the executor is routing" true \
	"$(timeout 20 bash fabriek -f "$F" watch --from 0 2>/dev/null | jq -r 'select(.stream == "events:executor" and .fields.name == "board") | .fields.json | fromjson | .routing' | tail -1)"

bash fabriek down "$F"
exit "$fail"
