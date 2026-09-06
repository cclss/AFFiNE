// Imported for the vocabulary only — the names of the settings and the values
// that count as deployed. Nothing here reads the global `env` object.
import { Namespace, NodeEnv } from '../env';

/** A setting, and the value it holds, that marks this process as a deployed one. */
export interface ProductionSignal {
  name: string;
  value: string;
  /** Why this value means "deployed". Reads as a clause after the pair. */
  reason: string;
}

interface ProductionSignalRule {
  name: string;
  /** The values of this variable that mean "deployed". Matched exactly. */
  values: readonly string[];
  reason: string;
}

/**
 * The settings that make a process a deployed one.
 *
 * Values are matched exactly, against the same vocabulary the `Env` class
 * accepts: a spelling `Env` would reject is not a quieter production, it is a
 * misconfiguration that `Env` itself refuses at construction.
 */
const PRODUCTION_SIGNALS: readonly ProductionSignalRule[] = [
  {
    name: 'NODE_ENV',
    values: [NodeEnv.Production],
    reason: 'the process is running as a production build',
  },
  {
    name: 'AFFINE_ENV',
    // Beta is a shared deployment carrying real accounts, so it is as
    // off-limits to a fixed-password fixture as production is.
    values: [Namespace.Production, Namespace.Beta],
    reason: 'the process is pointed at a deployed namespace',
  },
];

/**
 * Every deployed setting found in `source`, in declaration order.
 *
 * Reads the raw environment rather than the global `env`, for two reasons.
 * `env` fills both of these variables in with their production value when they
 * are absent — the right default for a server booting with no configuration,
 * and exactly the wrong one here, where it would make every fresh clone look
 * like production. And `env` is built once at startup from whatever the
 * launcher happened to export, so a launcher that overwrites `NODE_ENV` on its
 * way in leaves `env` unable to report how the machine is actually configured.
 *
 * Absence is therefore read as "nobody configured this box", not "production".
 */
export function detectProductionSignals(
  source: NodeJS.ProcessEnv = process.env
): ProductionSignal[] {
  return PRODUCTION_SIGNALS.flatMap(rule => {
    const value = source[rule.name];

    return value !== undefined && rule.values.includes(value)
      ? [{ name: rule.name, value, reason: rule.reason }]
      : [];
  });
}

/** `NODE_ENV=production — the process is running as a production build` */
function describe(signal: ProductionSignal): string {
  return `${signal.name}=${signal.value} — ${signal.reason}`;
}

/** `` `NODE_ENV` and `AFFINE_ENV` `` */
function nameList(signals: readonly ProductionSignal[]): string {
  const quoted = signals.map(signal => `\`${signal.name}\``);
  const last = quoted[quoted.length - 1];

  return quoted.length > 1
    ? `${quoted.slice(0, -1).join(', ')} and ${last}`
    : last;
}

/**
 * The refusal shown when a seed run finds itself in a deployed environment.
 *
 * Every blocking setting is named with the value it actually holds, so the
 * developer can go and look at the one variable that stopped the run instead of
 * guessing which of them the guard objected to. Every signal is listed, not
 * just the first: fixing one and re-running only to be refused again teaches
 * nothing.
 */
export function formatProductionRefusal(
  signals: readonly ProductionSignal[]
): string {
  return [
    'Refusing to run the standard seed profile — this environment is configured as a deployed one:',
    ...signals.map(signal => `  ${describe(signal)}`),
    `The profile creates accounts with publicly known passwords, so it must never run anywhere but a local machine. Unset ${nameList(signals)} to seed a local database.`,
  ].join('\n');
}

/**
 * What the standard seed assumes about a machine nobody has configured.
 *
 * The seed script used to hard-set `NODE_ENV=development` on every run, which
 * made the guard unfalsifiable — the setting it reads was overwritten to a safe
 * value moments before it looked. Defaults are therefore applied here, and only
 * where the variable is unset, so anything a launcher or a `.env` file did say
 * survives to reach {@link detectProductionSignals}.
 */
export const LOCAL_SEED_DEFAULTS: Readonly<Record<string, string>> = {
  NODE_ENV: NodeEnv.Development,
};

export function applyLocalSeedDefaults(
  target: NodeJS.ProcessEnv = process.env
): void {
  for (const [name, value] of Object.entries(LOCAL_SEED_DEFAULTS)) {
    target[name] ??= value;
  }
}
