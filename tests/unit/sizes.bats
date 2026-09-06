#!/usr/bin/env bats
# A declared size, as a number of bytes. Both memory and a role's quota are
# written the way a person writes them, and both have to be compared against a
# cap, so the parsing is one thing rather than two.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/sizes.sh
	source "$CAGEWORKS_ROOT/modules/sizes.sh"
}

teardown() {
	teardown_temp_dir
}

@test "a plain number is a count of bytes" {
	run cageworks_size_bytes 4096
	assert_success
	assert_output "4096"
}

@test "a suffix multiplies, and the units are powers of 1024" {
	run cageworks_size_bytes 1K
	assert_success
	assert_output "1024"

	run cageworks_size_bytes 8M
	assert_success
	assert_output "8388608"

	run cageworks_size_bytes 16G
	assert_success
	assert_output "17179869184"

	run cageworks_size_bytes 2T
	assert_success
	assert_output "2199023255552"
}

@test "the suffix is read whichever case it is written in" {
	run cageworks_size_bytes 8g
	assert_success
	assert_output "8589934592"
}

# The reason this exists at all. Comparing the strings would put 8G above 16G
# and hand a factory twice the memory its operator allowed.
@test "a bigger size is a bigger number even when its string sorts lower" {
	run cageworks_size_bytes 8G
	assert_success
	eight="$output"

	run cageworks_size_bytes 16G
	assert_success
	sixteen="$output"

	[ "$eight" -lt "$sixteen" ]
}

@test "a size that is not one is refused rather than read as zero" {
	run cageworks_size_bytes "lots"
	assert_failure
	assert_output --partial "lots"
}

@test "an empty size is refused" {
	run cageworks_size_bytes ""
	assert_failure
}

@test "a size with an unknown suffix is refused, naming what was written" {
	run cageworks_size_bytes "16Q"
	assert_failure
	assert_output --partial "16Q"
}

@test "a negative size is refused" {
	run cageworks_size_bytes "-1G"
	assert_failure
}
