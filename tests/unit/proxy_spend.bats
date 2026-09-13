#!/usr/bin/env bats
# The proxy's counting filter (ADR-037 point 4), driven with the bodies the
# Messages API answers. The scenarios are node's, beside the filter; this
# runs them so the suite carries them.

load ../test_helper/common

@test "the counting filter's scenarios pass under node with the API's own bodies" {
	run node --test "$CAGEWORKS_ROOT/modules/machine/spend.test.mjs"
	assert_success
}
