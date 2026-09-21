#!/usr/bin/env bats
# The proxy's counting filter (ADR-037 point 4), driven with the bodies the
# Messages API answers. The scenarios are node's, beside the filter; this
# runs them so the suite carries them.

load ../test_helper/common

@test "the counting filter's scenarios pass under node with the API's own bodies" {
	run node --test "$FABRIEK_ROOT/modules/machine/spend.test.mjs"
	assert_success
}

# ADR-067: one nginx for every factory on the host, a dictionary per
# factory named by the server block.
@test "the host's counting filter passes the same scenarios and keeps two factories' spend apart" {
	run node --test "$FABRIEK_ROOT/modules/host/spend.test.mjs"
	assert_success
}
