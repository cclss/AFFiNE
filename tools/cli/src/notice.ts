/**
 * The text of the `build` command's target guidance.
 *
 * Kept apart from the command itself so the wording is a pure function of the
 * alias table — no clipanion, no workspace, testable on its own.
 *
 * Lines are plain text with no blank lines and no trailing newline: the caller's
 * `Logger` owns the `[build]` prefix, the colour and the line splitting, and it
 * drops empty lines.
 */

import type { PackageName } from '@affine-tools/utils/workspace';

import { type AliasMap, DEFAULT_PACKAGE, formatTargetList } from './target';

/** The one line both notices use to hand over to the target list. */
export const PICK_ANOTHER_TARGET =
  'Available targets — pick one with `yarn build -p <target>`:';

/** Printed before a bare `yarn build` falls back to the default target. */
export function defaultTargetNotice(
  target: PackageName = DEFAULT_PACKAGE,
  aliases?: AliasMap
): string {
  return [
    `No target given — building the default target ${target}.`,
    PICK_ANOTHER_TARGET,
    formatTargetList(aliases),
  ].join('\n');
}

/**
 * Printed when `-p` names something the workspace does not have.
 *
 * It always quotes back what was typed, so the reader can spot their own typo.
 */
export function unknownTargetNotice(input: string, aliases?: AliasMap): string {
  return [
    `Unknown build target '${input}'.`,
    PICK_ANOTHER_TARGET,
    formatTargetList(aliases),
    `Any workspace package name works too, e.g. \`yarn build -p ${DEFAULT_PACKAGE}\`.`,
  ].join('\n');
}
