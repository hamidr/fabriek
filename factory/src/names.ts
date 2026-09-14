// The names the rest of the system accepts, mirrored from modules/names.sh so
// that a name the bus or a command carries is one a path, a ref, a container
// and an interface would all take. Refused here rather than escaped, for the
// same reason the shell side refuses: anything outside the alphabet is not a
// name but an attempt.

/** Factory, role and capability names share one alphabet (names.sh). */
export const NAME = /^[a-zA-Z0-9][a-zA-Z0-9-]*$/;

/** A role is also its cage, a machine name to nspawn (names.sh). */
export const ROLE_NAME_MAX = 64;

export function isName(value: unknown): value is string {
  return typeof value === "string" && NAME.test(value);
}

export function isRoleName(value: unknown): value is string {
  return isName(value) && value.length <= ROLE_NAME_MAX;
}

/** An issue number on the forge: a positive integer and nothing else. */
export function isIssue(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value > 0;
}
