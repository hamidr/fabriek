import { stat } from "node:fs/promises";

/** Whether a credential has gone too long unrefreshed (ADR-072 point 5). */
export interface Credentials {
  /** The host of a credential past its maxAge, or null when none is. */
  overdue(): Promise<string | null>;
}

export interface CredentialAgeOptions {
  /** Per host, the most seconds its credential may go unrefreshed. */
  maxAge: Record<string, number>;
  /** Where the refresh touches a stamp per host. Only a time is read, never a token. */
  dir: string;
  now?: () => number;
}

/**
 * A credential with no stamp has never been filed, so its age is not known
 * and it counts as overdue: a limit declared is a limit kept.
 */
export function credentialAge(o: CredentialAgeOptions): Credentials {
  const now = o.now ?? Date.now;
  return {
    async overdue() {
      for (const [host, limit] of Object.entries(o.maxAge)) {
        const filed = await stat(`${o.dir}/${host}`).then((s) => s.mtimeMs, () => null);
        if (filed === null || (now() - filed) / 1000 > limit) return host;
      }
      return null;
    },
  };
}
