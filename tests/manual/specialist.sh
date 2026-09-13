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
## Every line is asked with `fabriek role`, the real session, from the role's
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

scenario "pi itself lists the skill in its system prompt"
gated "jvm-profile in the system prompt" "pi 0.84.4 has no flag that prints its skills; read the session's first system message in the role's ~/.pi/sessions"

exit "$fail"
