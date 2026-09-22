// The accounts a factory holds on the host (ADR-068 point 4, ADR-069 point
// 2). One Forgejo and one nats-server serve every factory, and neither
// keeps two accounts of the same name, so an account carries the factory's
// name as the role's cage already does; the cores go on speaking bare
// roles, and this is where the two names meet.

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
