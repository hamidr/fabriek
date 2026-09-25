#!/usr/bin/env bash
## ADR-042's proof, which needs a machine and so cannot be a bats test: what
## a role's session can see of who it is, asked of the session rather than
## of the module that declared it. A module test that the profile carries
## jdk passes on a machine where no cage can run it.
##
## Wants a scratch directory holding an operator config and a running
## machine of a factory whose backend role names the java specialist, as the
## example does:
##
##   export FABRIEK_PROOF_DIR=/tmp/fabriek-proof
##   tests/manual/specialist.sh
##
## Every line is asked with `fabriek enter`, the real session, from the role's
## own cage. The single-quoted $PI_CODING_AGENT_DIR below expands there,
## where it is set, and not here.
# shellcheck disable=SC2016
set -uo pipefail
F="${F:-example}"
# shellcheck source=tests/manual/lib.sh
. "$(dirname "$0")/lib.sh"
ROLE="${ROLE:-backend}"

scenario "A role's specialists' tools are on its PATH, in front of the floor"
given "the $ROLE role of $F names the java specialist"
when "the session asks which java it runs"
check "java resolves" "yes" "$(in_cage "$ROLE" sh -c 'command -v java >/dev/null && echo yes')"
check "the floor is still under it" "yes" "$(in_cage "$ROLE" sh -c 'command -v sed >/dev/null && command -v pi >/dev/null && echo yes')"

scenario "pi reads the role's own directory: the prompt and the skills"
when "the session lists what PI_CODING_AGENT_DIR carries"
check "APPEND_SYSTEM.md opens with the guidance every role gets (ADR-054)" "# Working as a factory role" \
	"$(in_cage "$ROLE" sh -c 'head -1 "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md"')"
check "the specialists' headings follow it, in the declared order" "## committer,## developer,## java" \
	"$(in_cage "$ROLE" sh -c 'grep -E "^## (committer|developer|java)$" "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md" | paste -sd,')"
check "the java skill is where pi discovers skills" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -f "$PI_CODING_AGENT_DIR/skills/jvm-profile/SKILL.md" && echo yes')"
check "the loop is beside them" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -f "$PI_CODING_AGENT_DIR/extensions/fabriek/index.ts" && echo yes')"

scenario "The language server the specialist declared is where pi-lsp reads it"
when "the session reads lsp.json from the directory pi-lsp is pointed at"
check "PI_AGENT_DIR is the pi directory" "yes" \
	"$(in_cage "$ROLE" sh -c 'test "$PI_AGENT_DIR" = "$PI_CODING_AGENT_DIR" && echo yes')"
check "jdtls is declared for java files" "jdtls" \
	"$(in_cage "$ROLE" sh -c 'jq -r ".servers[] | select(.include[0] == \"**/*.java\") | .id" "$PI_AGENT_DIR/lsp.json"')"
check "its binary exists in the cage" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -x "$(jq -r ".servers[0].bin" "$PI_AGENT_DIR/lsp.json")" && echo yes')"
check "the extension is beside the loop" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -f "$PI_CODING_AGENT_DIR/extensions/pi-lsp/index.ts" && echo yes')"
gated "diagnostics appended after a write" "needs a model: write a Java file with an unused import through pi and read the diagnostics in the session transcript"

scenario "The worktree is indexed and the codegraph tools are in pi (ADR-049)"
when "the session asks codegraph about the tree it was handed"
check "the index was built before the role got the tree" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -f .codegraph/codegraph.db && echo yes')"
check "the index is the role's own" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -O .codegraph/codegraph.db && echo yes')"
check "codegraph is on the role's PATH and answers" "1.6.0" \
	"$(in_cage "$ROLE" sh -c 'codegraph --version')"
check "the extension is beside the loop" "yes" \
	"$(in_cage "$ROLE" sh -c 'test -f "$PI_CODING_AGENT_DIR/extensions/pi-codegraph/index.ts" && echo yes')"
## The model step, when the operator allows it: the role, idle, is asked a
## question only the graph answers well, and its stream is read for the
## tools it reached for. Wants a symbol the worked repository defines and
## calls; the example's importer has parse_line. Off unless
## FABRIEK_PROOF_MODEL=1, because it spends tokens.
if [ "${FABRIEK_PROOF_MODEL:-}" = 1 ]; then
	symbol="${SYMBOL:-parse_line}"
	since="$(date +%s)000-0"
	when "the operator asks the idle role where $symbol is called from and what a change reaches"
	bash fabriek -f "$F" steer "$ROLE" "Where is $symbol called from, and what would a change to its return type reach? Use the codegraph tools, not grep." 2>/dev/null
	# shellcheck disable=SC2329  # invoked through eventually
	answered() {
		timeout 20 bash fabriek -f "$F" watch --from "$since" --stream "events:$ROLE" 2>/dev/null |
			jq -r 'select(.stream == "events:'"$ROLE"'" and .fields.name == "agent_end") | "ended"' | head -1
	}
	check "the role answers in a turn of its own" "ended" "$(eventually 180 ended answered)"
	tools="$(timeout 20 bash fabriek -f "$F" watch --from "$since" --stream "events:$ROLE" 2>/dev/null |
		jq -r 'select(.stream == "events:'"$ROLE"'" and .fields.name == "tool_call") | .fields.json | fromjson | .toolName' | sort -u | paste -sd,)"
	check "it reached for the graph" "yes" "$(printf '%s' "$tools" | grep -q 'codegraph_' && echo yes)"
	check "and not for grep" "yes" "$(printf '%s' "$tools" | grep -qv '^bash$' && echo yes)"
	echo "  tools: $tools"
else
	gated "codegraph_explore answers from the index" "set FABRIEK_PROOF_MODEL=1 to ask the idle role about a symbol and read its tools off the bus; spends tokens"
fi

scenario "The test-first guard reads what the specialists declared (ADR-044)"
when "the session reads tests.json beside the loop"
check "java sources are watched" "yes" \
	"$(in_cage "$ROLE" sh -c 'jq -e ".source | index(\"**/src/main/**\")" "$PI_CODING_AGENT_DIR/tests.json" >/dev/null && echo yes')"
gated "an edit without a test is refused" "needs a model: ask the role to add a method to a class under src/main with no test; the transcript shows the refusal and the bus shows guard_refused"

scenario "nixcage answers for the running cage (ADR-045)"
when "the machine is asked about the role's cage through nixcage"
## The scope's spelling is nixcage's to know (ADR-012 as amended): read
## off status and asked back, never composed here.
scope="$(cage_verb status "$F-$ROLE" 2>/dev/null | tr -d '\r' | sed -n 's|^running [0-9]* machine.slice/||p')"
check "status says running with a scope under machine.slice" "yes" "$([ -n "$scope" ] && echo yes)"
## The scope is the machine's (ADR-070), so its bound is read there.
check "the scope carries the memory bound" "yes" \
	"$(printf 'systemctl show -p MemoryMax --value %q\n' "$scope" | where_cages_are 2>/dev/null | grep -qv '^infinity$' && echo yes)"
check "a hand lands inside the actor's cage" "yes" \
	"$(in_cage "$ROLE" sh -c 'grep -q "'"$scope"'" /proc/1/cgroup && echo yes')"
# shellcheck disable=SC2016  # expands in the cage
check "a hand sees the actor's pi" "yes" \
	"$(in_cage "$ROLE" sh -c 'for p in /proc/[0-9]*; do c="$(tr "\0" " " <"$p/cmdline" 2>/dev/null)"; [ "${c%% *}" = pi ] && echo yes && break; done' | tr -d '\r')"
gated "enter --print-argv matches seam.bats" "compare nixcage-container enter --print-argv for the role against the line seam.bats asserts; needs the role's uid and paths from the machine"

scenario "The guidance is the front of the prompt, and the repository's is in the brief (ADR-054)"
when "the session reads the front of APPEND_SYSTEM.md and the tree it was handed"
check "the machine's guidance opens the system prompt" "# Working as a factory role" \
	"$(in_cage "$ROLE" sh -c 'head -1 "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md"')"
## A role's branch is cut from main once and kept; the guidance reaches a
## role when its branch has it, so what is asked is the clone's main.
check "the repository's guidance is on main in the role's clone, for a brief to read" "yes" \
	"$(in_cage "$ROLE" sh -c 'git cat-file -e main:docs/factory-guidance.md 2>/dev/null && echo yes')"
if [ "${FABRIEK_PROOF_MODEL:-}" = 1 ]; then
	## The brief is what the loop prompts a role with; a role asked what
	## its brief said of this factory answers from it.
	since="$(date +%s)000-0"
	when "the operator asks the idle role what its brief said under 'this factory:'"
	bash fabriek -f "$F" steer "$ROLE" "Quote the first line under the heading 'this factory:' in your last task brief, or say 'no brief' if you have had none this session." 2>/dev/null
	# shellcheck disable=SC2329  # invoked through eventually
	answered_guidance() {
		timeout 20 bash fabriek -f "$F" watch --from "$since" --stream "events:$ROLE" 2>/dev/null |
			jq -r 'select(.stream == "events:'"$ROLE"'" and .fields.name == "agent_end") | "ended"' | head -1
	}
	check "the role answers" "ended" "$(eventually 180 ended answered_guidance)"
	gated "the brief carries the repository's guidance" "read the role's answer in the console or its transcript; a role with no task this session has had no brief"
else
	gated "the brief carries 'this factory:'" "set FABRIEK_PROOF_MODEL=1 and file a task; the role's transcript shows the brief with the repository's guidance under 'this factory:'"
fi

scenario "A replicated role is N roles, each with a cage of its own (ADR-053)"
mapfile -t replicas < <(jq -r '.declaration.roles | keys[] | select(test("^[a-z]+-[0-9]+$"))' "$(spec_json)" 2>/dev/null)
if [ "${#replicas[@]}" -ge 2 ]; then
	when "the machine is asked about each replica"
	for r in "${replicas[@]}"; do
		check "$r has a cage of its own" "yes" \
			"$(cage_verb status "$F-$r" 2>/dev/null | grep -q '^running ' && echo yes)"
		check "$r has a worktree of its own" "yes" \
			"$(in_cage "$r" sh -c 'test -d .git -o -f .git && git rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo yes')"
	done
	## Asked of the machine: inside a cage every role is root, mapped onto
	## its own host uid, and it is the host uid that tells them apart.
	check "the replicas' uids differ" "yes" \
		"$([ "$(cage_verb uid "$F-${replicas[0]}" 2>/dev/null)" != "$(cage_verb uid "$F-${replicas[1]}" 2>/dev/null)" ] && echo yes)"
	check "no role carries the base name" "absent" \
		"$(jq -r --arg b "${replicas[0]%-*}" '.declaration.roles | has($b) | if . then "present" else "absent" end' "$(spec_json)")"
else
	gated "a replicated role's cages" "declare replicas = 2 on a role of $F and run up -u; the proof then asks each replica's cage"
fi

scenario "An assignment past the declared concurrency is refused (ADR-055)"
## The operator's own assign goes through the executor's gate as the
## decider's would (ADR-039), so the refusal is asked for directly rather
## than waited for: a decider that is told the ceiling never asks past it.
## Filed at a stage that more roles than the ceiling provide, so the
## refusal is the ceiling's and not "holds work already"; the launcher
## files at the first stage only, so the verb goes through send with the
## files put on the machine by hand. Each is a real small task, since a
## role handed a tautology reports blocked and asks, at some cost.
concurrency="$(jq -r '.declaration.resources.concurrency // 0' "$(spec_json)")"
busy_stage="$(jq -r --argjson n "$concurrency" '
	.declaration as $d | $d.workflows.ship.stages[].needs as $s
	| select(([$d.roles[] | select(.provides | index($s))] | length) > $n) | $s' "$(spec_json)" | head -1)"
if [ "${FABRIEK_PROOF_MODEL:-}" = 1 ] && [ "$concurrency" -ge 1 ] 2>/dev/null && [ -n "$busy_stage" ]; then
	given "the factory allows $concurrency tasks in flight and more roles than that provide $busy_stage"
	when "the operator files one more goal than that at $busy_stage and assigns each to a free role"
	since="$(date +%s)000-0"
	mapfile -t providers < <(jq -r --arg s "$busy_stage" '.declaration.roles | to_entries[] | select(.value.provides | index($s)) | .key' "$(spec_json)")
	for i in $(seq 1 $((concurrency + 1))); do
		dir="/var/lib/nixcage/filed/proof-$(date +%s)-$i"
		onhost "mkdir -p $dir && printf '%s\n' 'Add a docstring to parse_line ($i)' >$dir/title && printf '%s\n' 'acceptance: parse_line has a one-line docstring saying what it splits on; nothing else changes' >$dir/body" >/dev/null 2>&1
		bash fabriek -f "$F" send "{\"verb\":\"file\",\"titleFile\":\"$dir/title\",\"bodyFile\":\"$dir/body\",\"stage\":\"$busy_stage\"}" >/dev/null 2>&1
	done
	## The issues the executor opened for them, newest first off the board.
	sleep 15
	forge="$(onhost "cat '$ETC/bridge.json'" 2>/dev/null | tr -d '\r' | sed -n 's/.*"forgejo":"\([^"]*\)".*/\1/p')"
	mapfile -t issues < <(onhost "curl -s -H \"Authorization: token \$(cat $STATE/forge/operator-token)\" 'http://$forge/api/v1/repos/$F-operator/$F/issues?state=open&limit=50'" 2>/dev/null | tr -d '\r' |
		jq -r --arg t "Add a docstring to parse_line" '.[] | select(.title | startswith($t)) | .number' | head -n $((concurrency + 1)))
	check "the executor opened one issue per goal" "$((concurrency + 1))" "${#issues[@]}"
	k=0
	for n in "${issues[@]}"; do
		bash fabriek -f "$F" send "{\"verb\":\"assign\",\"issue\":$n,\"role\":\"${providers[$k]}\"}" >/dev/null 2>&1
		k=$((k + 1))
		sleep 3
	done
	# shellcheck disable=SC2329  # invoked through eventually
	## The watch ends by timeout, so under pipefail the pipeline fails
	## whatever grep found; the answer is read from grep's output instead.
	refused() {
		local found
		found="$(timeout 20 bash fabriek -f "$F" watch --from "$since" --stream events:executor 2>/dev/null |
			jq -r 'select(.stream == "events:executor" and .fields.name == "command") | .fields.json | fromjson | select(.command.verb == "assign" and .result.ok == false) | .result.reason' |
			grep -m1 -c "concurrency is $concurrency and $concurrency roles hold work")"
		[ "${found:-0}" -ge 1 ] && echo refused
	}
	check "the executor refuses the assign past the ceiling, naming both numbers" "refused" "$(eventually 6 refused refused)"
	echo "  note: $((concurrency + 1)) tasks were filed at $busy_stage and are left on the board"
else
	gated "the concurrency refusal on a live board" "set FABRIEK_PROOF_MODEL=1 with concurrency declared below the roles providing some stage; the proof files one goal more than the ceiling there, assigns each, and reads the refusal off the bus"
fi

scenario "pi itself lists the skill in its system prompt"
gated "jvm-profile in the system prompt" "pi 0.84.4 has no flag that prints its skills; read the session's first system message in the role's ~/.pi/sessions"

exit "$fail"
