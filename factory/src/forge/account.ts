// The accounts a factory holds on the host's forge (ADR-068 point 4). One
// Forgejo serves every factory, so an account carries the factory's name as
// its cage and its bus user already do; the cores go on speaking bare roles,
// and this is where the two names meet.

/** The account a role holds: the name its cage and its bus user carry. */
export function accountOf(factory: string, role: string): string {
  return `${factory}-${role}`;
}

/**
 * The role a login names, for this factory. A login the factory does not own
 * (another factory's account, or a person's) is not this factory's to rename
 * and is answered as it is.
 */
export function roleOf(factory: string, login: string): string {
  const prefix = `${factory}-`;
  return login.startsWith(prefix) ? login.slice(prefix.length) : login;
}
