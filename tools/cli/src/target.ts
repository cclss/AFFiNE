import { AliasToPackage } from '@affine-tools/utils/distribution';
import type { PackageName } from '@affine-tools/utils/workspace';

/**
 * A read-only view of the alias table. Every function here takes the table as an
 * injectable argument so it stays a pure function of its inputs — the real
 * {@link AliasToPackage} is only the default.
 */
export type AliasMap = ReadonlyMap<string, PackageName>;

/**
 * The target used when no package is given on the command line.
 *
 * `@affine/web` is the front door of the product, so an unqualified
 * `yarn build` / `yarn dev` means "the browser app".
 */
export const DEFAULT_PACKAGE = '@affine/web' as PackageName;

/**
 * The aliases worth showing in CLI guidance, ordered by how likely a newcomer is
 * to need them.
 *
 * `AliasToPackage` also derives an alias for every workspace package (hundreds of
 * them), which is useless as a printed list. This is the curated subset; it is
 * always filtered through the alias table before being shown, so it can never
 * advertise a target that does not exist.
 */
export const FEATURED_ALIASES: readonly string[] = Object.freeze([
  'web',
  'admin',
  'electron',
  'desktop',
  'renderer',
  'mobile',
  'ios',
  'android',
  'server',
  'gql',
]);

/** One printable row of the target list: the alias and what it expands to. */
export interface TargetEntry {
  alias: string;
  package: PackageName;
}

/**
 * Resolve a user supplied package name or alias to a package name.
 *
 * An empty, missing or whitespace-only input resolves to {@link DEFAULT_PACKAGE}.
 * An input that is not a known alias is returned as-is: whether that package
 * actually exists is the workspace's call, not this module's.
 */
export function resolveTarget(
  nameOrAlias?: string | null,
  aliases: AliasMap = AliasToPackage
): PackageName {
  const input = nameOrAlias?.trim();

  if (!input) {
    return DEFAULT_PACKAGE;
  }

  return aliases.get(input) ?? (input as PackageName);
}

/** The curated aliases that actually exist in the alias table, in display order. */
export function featuredTargets(
  aliases: AliasMap = AliasToPackage
): TargetEntry[] {
  return FEATURED_ALIASES.flatMap(alias => {
    const pkg = aliases.get(alias);
    return pkg ? [{ alias, package: pkg }] : [];
  });
}

/** Every alias the CLI accepts, sorted, including the per-package ones. */
export function listAliases(aliases: AliasMap = AliasToPackage): string[] {
  return Array.from(aliases.keys()).sort();
}

/** Every package name reachable through the alias table, sorted and deduped. */
export function listPackages(
  aliases: AliasMap = AliasToPackage
): PackageName[] {
  return Array.from(new Set(aliases.values())).sort() as PackageName[];
}

/**
 * Render the curated targets as aligned `alias → package` rows, one per line.
 *
 * The rows carry no heading and no trailing newline: callers own the framing.
 */
export function formatTargetList(
  aliases: AliasMap = AliasToPackage,
  { indent = '  ' }: { indent?: string } = {}
): string {
  const entries = featuredTargets(aliases);
  const width = entries.reduce(
    (max, { alias }) => Math.max(max, alias.length),
    0
  );

  return entries
    .map(
      ({ alias, package: pkg }) => `${indent}${alias.padEnd(width)} → ${pkg}`
    )
    .join('\n');
}

/** The signals that decide whether a prompt can be answered by a human. */
export interface InteractivityProbe {
  /** Whether stdin is attached to a terminal. */
  isTTY?: boolean;
  env?: Record<string, string | undefined>;
}

/**
 * True when nothing can answer an interactive prompt — no terminal on stdin, or
 * a `CI` environment variable is set. Callers must pick a default instead of
 * asking.
 */
export function isNonInteractive({
  isTTY = process.stdin.isTTY,
  env = process.env,
}: InteractivityProbe = {}): boolean {
  return !isTTY || !!env.CI;
}
