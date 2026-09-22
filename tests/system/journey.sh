#!/usr/bin/env bash
## The factory as a system, on this host, with no cage and no model: the bus
## and the forge for real on localhost, the real machine program preparing
## them, the real executor routing, the real relay printing, and where a
## cage would run pi, a scripted actor and a scripted decider that speak the
## same protocol through the same bindings (factory/src/fake-actor,
## factory/src/fake-decider). What it proves is everything but the model
## and the cage: PRD-006's journey from a filed goal to a mirrored record,
## and the refusals along the way.
##
##   nix develop --command tests/system/journey.sh
##
## FABRIEK_PROOF_DIR names where it works; a fresh temp dir otherwise.
## Everything it starts is killed on exit. On a Mac the forge is Gitea
## (flake.nix says why); the API and CLI it drives are the ones the forge
## modules use on Forgejo, and the machine proofs are the check on Forgejo.
set -uo pipefail
F=acme
export FABRIEK_PROOF_DIR="${FABRIEK_PROOF_DIR:-$(mktemp -d)}"
W="$FABRIEK_PROOF_DIR/system"
rm -rf "$W"
STATE="$W/state" ETC="$W/etc" BIN="$W/bin" LOG="$W/log" FORGE="$W/forge" RUN="$W/run"
mkdir -p "$STATE" "$ETC" "$BIN" "$LOG" "$FORGE" "$RUN" "$W/facts"
## The facts a host writes per factory (ADR-067), which lib.sh reads to
## know where a factory's state is: here there is no host, so this run
## writes its own, for the state and directories it made above.
cat >"$W/facts/$F.env" <<EOF
FABRIEK_FACTORY=$F
FABRIEK_STATE=$STATE
FABRIEK_ETC=$ETC
FABRIEK_RUN=$RUN
FABRIEK_BRIDGE=lo
FABRIEK_BRIDGE_HOST=127.0.0.1
EOF
export FABRIEK_FACTORIES="$W/facts"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/../manual/lib.sh"
ROOT="$PWD"
## The prepared mark is per boot, under /run on a machine (ADR-057); here
## under the scratch directory, since there is no machine.
export FABRIEK_STATE="$STATE" FABRIEK_ETC="$ETC" FABRIEK_RUN="$RUN" FABRIEK_FACTORY="$F"
export PATH="$BIN:$PATH" FABRIEK_LIB="$ROOT/modules"

## Everything this run starts, and everything a run before it left: the
## executor's sessions are its children and not this script's, so they are
## found by the package they run from. A stale actor on a fresh bus is a
## second builder, and the first check it fools is "ready".
DIST="$ROOT/factory/dist"
pids=()
# shellcheck disable=SC2329  # invoked by the trap
cleanup() {
	local p
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "$DIST/" 2>/dev/null
	pkill -P $$ 2>/dev/null
	wait 2>/dev/null
}
trap cleanup EXIT
pkill -f "$DIST/" 2>/dev/null
pkill -f "valkey-server 127.0.0.1:183" 2>/dev/null
pkill -f "$FORGE/app.ini" 2>/dev/null

## A port nothing listens on.
free_port() {
	local port
	for port in $(seq 18300 18399); do
		(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || { echo "$port"; return 0; }
	done
	return 1
}
VALKEY_PORT="$(free_port)"
FORGE_PORT="$((VALKEY_PORT + 1))"

## The declaration and the plan a build would have put on the machine.
cat >"$ETC/declaration.json" <<JSON
{ "name": "$F",
  "roles": { "builder": { "command": ["pi"], "provides": ["build"] },
             "reviewer": { "command": ["pi"], "provides": ["review"] } },
  "workflows": { "ship": { "stages": [ { "needs": "build" }, { "needs": "review" } ] } },
  "resources": { "taskAttempts": 2 } }
JSON
cat >"$ETC/bridge.json" <<JSON
{ "bridge": "fabriek-$F", "host": "127.0.0.1", "prefix": 24,
  "cages": { "builder": "127.0.0.10", "reviewer": "127.0.0.11", "decider": "127.0.0.2" },
  "proxy": "127.0.0.1:1", "forgejo": "127.0.0.1:$FORGE_PORT", "valkey": "127.0.0.1:$VALKEY_PORT" }
JSON

## What the machine has and this host does not: the uid primitive, whose
## answer here is this user; systemd, whose restart of the ACL unit is the
## machine verb itself and whose restart of the executor is this script's;
## and forgejo as the wrapper the machine installs, over whichever forge
## the devShell carries.
cat >"$BIN/nixcage-container" <<STUB
#!/usr/bin/env bash
case "\$1" in uid) id -u ;; *) echo "nixcage-container: \$*: not on this host" >&2; exit 1 ;; esac
STUB
cat >"$BIN/systemctl" <<STUB
#!/usr/bin/env bash
case "\$*" in
*fabriek-$F-bus-acl*) exec fabriek-container bus-acl $F ;;
*) exit 0 ;;
esac
STUB
## The programs as the tree holds them, run by bash as the suite runs them.
cat >"$BIN/fabriek-container" <<STUB
#!/usr/bin/env bash
exec bash "$ROOT/fabriek-container" "\$@"
STUB
forge_bin="$(command -v forgejo || command -v gitea)"
cat >"$BIN/forgejo" <<STUB
#!/usr/bin/env bash
exec env FORGEJO_WORK_DIR="$FORGE" GITEA_WORK_DIR="$FORGE" "$forge_bin" --config "$FORGE/app.ini" "\$@"
STUB
chmod +x "$BIN"/*

## The repository the factory works: the operator's checkout on this host
## (ADR-067 point 5), one commit on main, with main checked out and a file
## the operator is editing, both of which nothing in the factory may touch.
ORIGIN="$W/checkout"
git init -q -b main "$ORIGIN"
echo "# acme" >"$ORIGIN/README.md"
git -C "$ORIGIN" add README.md
git -C "$ORIGIN" -c user.name=operator -c user.email=operator@acme.invalid -c commit.gpgsign=false commit -q -m "first"
echo "draft" >"$ORIGIN/NOTES.md"
CHECKOUT_HEAD="$(git -C "$ORIGIN" rev-parse HEAD)"

scenario "The bus and the forge come up on this host"
valkey-server --bind 127.0.0.1 --port "$VALKEY_PORT" --save "" --appendonly no --protected-mode no >"$LOG/valkey" 2>&1 &
pids+=($!)
cat >"$FORGE/app.ini" <<INI
APP_NAME = fabriek
RUN_MODE = prod
[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = $FORGE_PORT
DOMAIN = 127.0.0.1
ROOT_URL = http://127.0.0.1:$FORGE_PORT/
DISABLE_SSH = true
OFFLINE_MODE = true
[database]
DB_TYPE = sqlite3
PATH = $FORGE/data.db
[repository]
ROOT = $FORGE/repos
[security]
INSTALL_LOCK = true
[service]
DISABLE_REGISTRATION = true
[mailer]
ENABLED = false
[log]
MODE = file
ROOT_PATH = $FORGE/log
LEVEL = Warn
INI
forgejo web >"$LOG/forge" 2>&1 &
pids+=($!)
forge="http://127.0.0.1:$FORGE_PORT/api/v1"
# shellcheck disable=SC2329  # invoked through eventually
forge_up() { curl -s -o /dev/null -w '%{http_code}' "$forge/version"; }
check "the forge answers" 200 "$(eventually 60 200 forge_up)"
check "the bus answers" PONG "$(valkey-cli -p "$VALKEY_PORT" ping 2>/dev/null)"

scenario "The machine program prepares the factory on them"
when "factory-prepare runs as fabriek up would run it"
check "prepare succeeds" "$F: prepared" "$(fabriek-container factory-prepare "$F" "$ORIGIN" 2>"$LOG/prepare" | tail -1)"
api() {
	local method="$1" path="$2" body="${3:-}"
	curl -s -X "$method" -H "Authorization: token $(cat "$STATE/forge/operator-token")" \
		-H 'Content-Type: application/json' ${body:+-d "$body"} "$forge$path"
}
repo="/repos/operator/$F"
check "the repository exists on the forge" "$F" "$(api GET "$repo" | jq -r .name)"
check "every stage is a label, with the executor's and memory" "assigned,assigning,blocked,build,memory,review" "$(api GET "$repo/labels" | jq -r '[.[].name] | sort | join(",")')"
check "each role has a memory issue opened as itself" "builder,reviewer" "$(api GET "$repo/issues?state=all&labels=memory&type=issues" | jq -r '[.[].user.login] | sort | join(",")')"
check "the bus refuses a connection that names nobody" NOAUTH "$(valkey-cli -p "$VALKEY_PORT" ping 2>&1 | grep -o NOAUTH)"
as_executor() { VALKEYCLI_AUTH="$(cat "$STATE/bus/executor")" valkey-cli -p "$VALKEY_PORT" --user executor --no-auth-warning "$@"; }
check "the executor may speak" PONG "$(as_executor ping)"
## Each asked with a well-formed line: DRYRUN checks arity before permission.
for user in builder reviewer decider probes; do
	for line in "EVAL x 0" "CONFIG GET x" "ACL LIST" "SCAN 0"; do
		# shellcheck disable=SC2086  # the line is words on purpose
		check "$user may not ${line%% *}" "no permissions" "$(as_executor ACL DRYRUN "$user" $line 2>&1 | grep -o 'no permissions' | head -1)"
	done
done
check "a role may not write another's control stream" "no permissions" "$(as_executor ACL DRYRUN builder XADD control:reviewer '*' k v 2>&1 | grep -o 'no permissions')"
check "a role may write its own" OK "$(as_executor ACL DRYRUN builder XADD control:builder '*' k v 2>&1)"
check "the decider may not write a mailbox" "no permissions" "$(as_executor ACL DRYRUN decider XADD mailbox:builder '*' k v 2>&1 | grep -o 'no permissions')"

scenario "The executor starts with scripted sessions where the cages would be"
## The factory's clone, as the first role session would have made it.
# shellcheck source=modules/names.sh
. "$ROOT/modules/names.sh"
# shellcheck source=modules/factory-clone.sh
. "$ROOT/modules/factory-clone.sh"
CLONE="$(fabriek_factory_clone_ensure "$STATE" "$F" "$ORIGIN")"
check "the factory has its clone" yes "$([ -d "$CLONE/.git" ] && echo yes || echo no)"
(cd "$ROOT/factory" && npm run build >"$LOG/build" 2>&1) || { echo "the package does not build; see $LOG/build"; exit 1; }
## The session program: what role-enter would compose on the machine, as
## environment for a scripted actor or decider instead of a cage.
cat >"$BIN/session" <<SESSION
#!/usr/bin/env bash
role="\${@: -1}"
export FABRIEK_ROLE="\$role"
export FABRIEK_CAPABILITIES="\$(jq -r --arg r "\$role" '.roles[\$r].provides // [] | join(",")' "$ETC/declaration.json")"
export FABRIEK_BUS="127.0.0.1:$VALKEY_PORT"
export FABRIEK_FORGE="$forge"
export FABRIEK_REPOSITORY="operator/$F"
export FABRIEK_BUS_PASSWORD="$STATE/bus/\$role"
export FABRIEK_FORGE_TOKEN="$STATE/forge/\$role-token"
export FABRIEK_BASE_BRANCH=main
export FABRIEK_CLONE="$CLONE"
export FABRIEK_DECLARATION="$ETC/declaration.json"
export FABRIEK_FAKE_OUTCOME_FILE="$W/outcome.\$role"
if [ "\$role" = decider ]; then
  exec node "$DIST/fake-decider/main.js" >>"$LOG/decider" 2>&1
else
  exec node "$DIST/fake-actor/main.js" >>"$LOG/actor-\$role" 2>&1
fi
SESSION
chmod +x "$BIN/session"
FABRIEK_SESSION_COMMAND="$BIN/session" node "$DIST/executor/main.js" >"$LOG/executor" 2>&1 &
pids+=($!)
node "$DIST/relay/main.js" --from 0-0 >"$LOG/relay" 2>&1 &
pids+=($!)
# shellcheck disable=SC2329  # invoked through eventually
ready_roles() { grep -o '"stream":"control:[a-z]*","id":"[^"]*","fields":{"kind":"ready"' "$LOG/relay" | grep -o 'control:[a-z]*' | sort -u | paste -sd, -; }
check "both roles announce ready on the bus, and the relay prints it" "control:builder,control:reviewer" "$(eventually 30 "control:builder,control:reviewer" ready_roles)"

scenario "A filed goal is worked through every stage with nothing typed after it"
when "the operator files a goal"
title="the importer handles empty files"
check "task-file is accepted" "$F: filed at build" "$(fabriek-container task-file "$F" ship "$title" "acceptance: an empty file imports as no rows" 2>>"$LOG/operator" | tail -1)"
# shellcheck disable=SC2329  # invoked through eventually
issue_by_title() { api GET "$repo/issues?state=all&type=issues&limit=50" | jq -r --arg t "$title" '.[] | select(.title == $t) | .number' | head -1; }
number="$(eventually 30 x issue_by_title)"
check "the executor opens an issue for it" yes "$([ -n "$number" ] && echo yes || echo no)"
# shellcheck disable=SC2329  # invoked through eventually
state_of() { api GET "$repo/issues/$1" | jq -r '.state'; }
## The scripted factory outruns a poll of the board, so the passage through
## each state is read off the relay and the thread, and the board is asked
## for where it ended.
# shellcheck disable=SC2329  # invoked through eventually
relay_has() { grep -q "$1" "$LOG/relay" && echo yes || echo no; }
check "the issue is filed at the first stage" yes "$(eventually 30 yes relay_has "\"name\":\"command\".*\\\\\"verb\\\\\":\\\\\"file\\\\\".*\\\\\"ok\\\\\":true")"
check "the decider asks for the builder and the executor sends the pointer" yes "$(eventually 60 yes relay_has "\"stream\":\"mailbox:builder\".*\"kind\":\"assignment\",\"issue\":\"$number\"")"
check "the builder acks it on its control stream" yes "$(eventually 30 yes relay_has "\"stream\":\"control:builder\".*\"kind\":\"ack\",\"issue\":\"$number\"")"
check "the reviewer is sent it next, after the builder's done moved it" yes "$(eventually 90 yes relay_has "\"stream\":\"mailbox:reviewer\".*\"kind\":\"assignment\",\"issue\":\"$number\"")"
check "and it closes" closed "$(eventually 60 closed state_of "$number")"
check "the branch builder/work carries the builder's commit" 1 "$(git -C "$CLONE" rev-list --count main..builder/work)"
## The forge shows the executor's comments as the operator's, whose token
## it writes with; the attempt line names where the branch stood.
thread_of() { api GET "$repo/issues/$1/comments" | jq -r '.[] | "\(.user.login): \(.body | split("\n")[0] | sub(" \\(branch at [0-9a-f]+\\)$"; "") | sub(" \\(branch at none\\)$"; ""))"'; }
## Each outcome is followed by the executor's trace of the attempt, cut
## from the role's events and the probes (ADR-051); the probes do not run
## here, so the trace names the scripted actor's tool call and no executable.
check "the thread reads: attempt at build, outcome, its trace, attempt 1 at review, outcome, its trace" "operator: attempt 1 started for builder at build
builder: outcome: done
operator: trace: attempt 1 of builder
operator: attempt 1 started for reviewer at review
reviewer: outcome: done
operator: trace: attempt 1 of reviewer" "$(thread_of "$number")"
trace_of() { api GET "$repo/issues/$1/comments" | jq -r '[.[] | select(.body | startswith("trace: attempt 1 of builder"))][0].body'; }
check "the builder's trace counts the tool it called" "tools: git 1" "$(trace_of "$number" | grep '^tools:')"
check "the builder's memory was rewritten by the script" "last task: #$number (done)" "$(api GET "$repo/issues?state=all&labels=memory&type=issues" | jq -r '.[] | select(.user.login == "builder") | .body')"
check "the builder's finding reached its stream" yes "$(grep -q '"stream":"findings:builder"' "$LOG/relay" && echo yes || echo no)"

scenario "A done with no commit is not done, and a failed task is retried by the same role"
echo done-without-commit >"$W/outcome.builder"
title2="a change that was never committed"
fabriek-container task-file "$F" ship "$title2" "" >>"$LOG/operator" 2>&1
title="$title2"
n2="$(eventually 30 x issue_by_title)"
# shellcheck disable=SC2329  # invoked through eventually
refused_note() { api GET "$repo/issues/$1/comments" | jq -r '[.[] | select(.body | startswith("not done"))] | length'; }
check "the executor refuses the done: the branch has no commit since the attempt began, and the thread says so" 1 "$(eventually 90 1 refused_note "$n2")"
echo "done" >"$W/outcome.builder"
check "the decider sends it again to the same role, as attempt 2" yes "$(eventually 90 yes relay_has "\"stream\":\"mailbox:builder\".*\"kind\":\"assignment\",\"issue\":\"$n2\",\"attempt\":\"2\"")"
check "and this time it moves on" yes "$(eventually 90 yes relay_has "\"stream\":\"mailbox:reviewer\".*\"kind\":\"assignment\",\"issue\":\"$n2\"")"

scenario "The operator pushes a role's branch and mirrors, and both land where they should"
check "push opens a pull request for builder/work" "$F: sent" "$(fabriek-container factory-send "$F" '{"verb":"push","role":"builder"}' 2>>"$LOG/operator" | tail -1)"
# shellcheck disable=SC2329  # invoked through eventually
pulls() { api GET "$repo/pulls?state=open" | jq -r '[.[].head.ref] | join(",")'; }
check "the forge shows the pull request" "builder/work" "$(eventually 30 builder/work pulls)"
check "mirror is requested" "$F: mirror requested" "$(fabriek-container factory-mirror "$F" 2>>"$LOG/operator" | tail -1)"
# shellcheck disable=SC2329  # invoked through eventually
record_in_clone() { git -C "$CLONE" rev-parse --verify --quiet refs/fabriek/record >/dev/null && echo yes || echo no; }
check "refs/fabriek/record lands in the clone" yes "$(eventually 60 yes record_in_clone)"
## The operator's side (ADR-067 point 5): the remote fabriek up adds to the
## checkout and the fetch every verb runs, as the operator, and nothing else
## writes it.
git -C "$ORIGIN" remote add "fabriek-$F" "$CLONE"
git -C "$ORIGIN" config --replace-all "remote.fabriek-$F.fetch" "+refs/heads/*:refs/heads/fabriek/$F/*"
git -C "$ORIGIN" config --add "remote.fabriek-$F.fetch" "+refs/fabriek/*:refs/fabriek/$F/*"
git -C "$ORIGIN" fetch -q "fabriek-$F"
check "the role's branch is in the checkout under the factory's name" "$(git -C "$CLONE" rev-parse refs/heads/builder/work)" "$(git -C "$ORIGIN" rev-parse "refs/heads/fabriek/$F/builder/work")"
check "the record is in the checkout under the factory's name, carrying every issue" "$(api GET "$repo/issues?state=all&type=issues&limit=100" | jq -r 'length')" "$(git -C "$ORIGIN" show "refs/fabriek/$F/record:issues.json" | jq -r 'length')"
check "the checkout's own branch has not moved" "$CHECKOUT_HEAD" "$(git -C "$ORIGIN" rev-parse HEAD)"
check "the operator's uncommitted file is as they left it" "?? NOTES.md" "$(git -C "$ORIGIN" status --porcelain)"
check "the relay printed the executor's board events" yes "$(grep -q '"name":"board"' "$LOG/relay" && echo yes || echo no)"

echo
if [ "$fail" -eq 0 ]; then echo "journey: every check passed (logs under $LOG)"; else echo "journey: a check failed (logs under $LOG)"; fi
## For looking around: FABRIEK_JOURNEY_HOLD=1 keeps everything up until
## interrupted, with the ports and the state directory printed above.
if [ -n "${FABRIEK_JOURNEY_HOLD:-}" ]; then
	echo "holding: bus 127.0.0.1:$VALKEY_PORT, forge $forge, state $STATE; interrupt to end"
	while sleep 60; do :; done
fi
exit "$fail"
