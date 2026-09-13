// The declaration as the machine carries it (ADR-040): validated and clamped
// by the build, written to /etc/fabriek/declaration.json, and read here by
// the executor and the decider. The table is modules/repo-declaration.sh's;
// this side only refuses what that table could not have produced, so a file
// it does refuse is one somebody wrote by hand.
import { isName, isRoleName } from "./names.js";

export interface Role {
  command: string[];
  provides: string[];
  shell?: string;
}

export interface Stage {
  needs: string;
  ready?: string[];
  done?: string;
  gate?: string;
}

export interface Workflow {
  stages: Stage[];
  budget?: { runs?: number };
  consults?: Record<string, string[]>;
}

export interface Resources {
  taskAttempts: number;
  tokens: number;
  runTimeoutSeconds: number;
  concurrency: number;
}

export interface Declaration {
  name: string;
  roles: Record<string, Role>;
  workflows: Record<string, Workflow>;
  resources: Resources;
}

/** The defaults the shell side has (fabriek-container's factory_limit). */
export const DEFAULTS: Resources = { taskAttempts: 3, tokens: 0, runTimeoutSeconds: 3600, concurrency: 0 };

export class DeclarationError extends Error {
  override name = "DeclarationError";
}

function refuse(message: string): never {
  throw new DeclarationError(message);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function names(v: unknown, what: string): string[] {
  if (!Array.isArray(v) || !v.every(isName)) refuse(`${what} must be a list of names`);
  return v as string[];
}

/** The declaration out of the file's text, or a DeclarationError. */
export function readDeclaration(text: string): Declaration {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    refuse("the declaration is not JSON");
  }
  if (!isRecord(raw)) refuse("the declaration is not an object");
  if (!isName(raw["name"])) refuse("name must be a usable name");
  if (!isRecord(raw["roles"]) || Object.keys(raw["roles"]).length === 0) refuse("roles must declare at least one role");

  const roles: Record<string, Role> = {};
  for (const [name, r] of Object.entries(raw["roles"])) {
    if (!isRoleName(name)) refuse(`role ${name}: not a usable role name`);
    if (!isRecord(r)) refuse(`role ${name}: not an object`);
    if (!Array.isArray(r["command"]) || !r["command"].every((w) => typeof w === "string")) {
      refuse(`role ${name}: command must be argv`);
    }
    const role: Role = { command: r["command"] as string[], provides: names(r["provides"], `role ${name}: provides`) };
    if (r["shell"] !== undefined) {
      if (typeof r["shell"] !== "string") refuse(`role ${name}: shell must be a name`);
      role.shell = r["shell"];
    }
    roles[name] = role;
  }

  const workflows: Record<string, Workflow> = {};
  const rawWorkflows = raw["workflows"];
  if (rawWorkflows !== undefined) {
    if (!isRecord(rawWorkflows)) refuse("workflows must be an object");
    for (const [name, w] of Object.entries(rawWorkflows)) {
      if (!isName(name)) refuse(`workflow ${name}: not a usable name`);
      if (!isRecord(w) || !Array.isArray(w["stages"])) refuse(`workflow ${name}: stages must be a list`);
      const stages: Stage[] = w["stages"].map((s: unknown, i: number) => {
        if (!isRecord(s) || !isName(s["needs"])) refuse(`workflow ${name} stage ${i}: needs a capability`);
        const stage: Stage = { needs: s["needs"] };
        if (s["ready"] !== undefined) stage.ready = names(s["ready"], `workflow ${name} stage ${i}: ready`);
        if (typeof s["done"] === "string") stage.done = s["done"];
        if (typeof s["gate"] === "string") stage.gate = s["gate"];
        return stage;
      });
      const workflow: Workflow = { stages };
      if (isRecord(w["budget"]) && typeof w["budget"]["runs"] === "number") workflow.budget = { runs: w["budget"]["runs"] };
      if (isRecord(w["consults"])) {
        workflow.consults = Object.fromEntries(
          Object.entries(w["consults"]).map(([k, v]) => [k, names(v, `workflow ${name}: consults ${k}`)]),
        );
      }
      workflows[name] = workflow;
    }
  }

  const res = isRecord(raw["resources"]) ? raw["resources"] : {};
  const number = (key: keyof Resources): number => {
    const v = res[key];
    if (v === undefined) return DEFAULTS[key];
    if (typeof v !== "number" || !Number.isInteger(v) || v < 0) refuse(`resources: ${key} must be a count`);
    return v;
  };
  const resources: Resources = {
    taskAttempts: number("taskAttempts"),
    tokens: number("tokens"),
    runTimeoutSeconds: number("runTimeoutSeconds"),
    concurrency: number("concurrency"),
  };

  return { name: raw["name"], roles, workflows, resources };
}

/** The roles that provide what a stage needs, in declaration order. */
export function capableRoles(d: Declaration, capability: string): string[] {
  return Object.entries(d.roles)
    .filter(([, r]) => r.provides.includes(capability))
    .map(([name]) => name);
}

export interface StageAt {
  workflow: string;
  index: number;
  needs: string;
  /** The capability the next stage needs, or null at the pipeline's end. */
  next: string | null;
}

/** A stage by its workflow and its label, which is the capability it needs. */
export function stageOf(d: Declaration, workflow: string, label: string): StageAt | null {
  const w = d.workflows[workflow];
  if (!w) return null;
  const index = w.stages.findIndex((s) => s.needs === label);
  if (index < 0) return null;
  const next = w.stages[index + 1];
  return { workflow, index, needs: label, next: next ? next.needs : null };
}
