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
check "APPEND_SYSTEM.md opens with the first specialist's heading" "## developer" \
	"$(in_cage "$ROLE" sh -c 'head -1 "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md"')"
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

scenario "The test-first guard reads what the specialists declared (ADR-044)"
when "the session reads tests.json beside the loop"
check "java sources are watched" "yes" \
	"$(in_cage "$ROLE" sh -c 'jq -e ".source | index(\"**/src/main/**\")" "$PI_CODING_AGENT_DIR/tests.json" >/dev/null && echo yes')"
gated "an edit without a test is refused" "needs a model: ask the role to add a method to a class under src/main with no test; the transcript shows the refusal and the bus shows guard_refused"

scenario "nixcage answers for the running cage (ADR-045)"
when "the machine is asked about the role's cage through nixcage"
check "status says running with the role's scope" "yes" \
	"$(sshm "nixcage-container status $ROLE" 2>/dev/null | grep -q "^running .* machine.slice/machine-$ROLE.scope\$" && echo yes)"
check "the scope carries the memory bound" "yes" \
	"$(sshm "systemctl show -p MemoryMax --value machine-$ROLE.scope" 2>/dev/null | grep -qv '^infinity$' && echo yes)"
check "a hand lands inside the actor's cage" "yes" \
	"$(in_cage "$ROLE" sh -c 'grep -q "machine-'"$ROLE"'.scope" /proc/1/cgroup && echo yes')"
gated "enter --print-argv matches seam.bats" "compare nixcage-container enter --print-argv for the role against the line seam.bats asserts; needs the role's uid and paths from the machine"

scenario "pi itself lists the skill in its system prompt"
gated "jvm-profile in the system prompt" "pi 0.84.4 has no flag that prints its skills; read the session's first system message in the role's ~/.pi/sessions"

exit "$fail"
