import { formatProductionRefusal, type ProductionSignal } from './environment';
import {
  type SeededAccount,
  STANDARD_SEED_ACCOUNTS,
  type StandardSeedResult,
} from './standard';

const COLUMNS = ['EMAIL', 'PASSWORD', 'ROLE', 'STATUS'] as const;

/**
 * Minimum gap between two aligned columns. Columns are padded to a shared
 * boundary, matching the alignment of the seed help block.
 */
const COLUMN_GAP = '  ';

/**
 * Renders rows as a left-aligned text table. The first row is the header.
 */
function renderTable(rows: string[][]): string {
  const widths = rows[0].map((_, column) =>
    Math.max(...rows.map(row => row[column].length))
  );

  return rows
    .map(row =>
      row
        .map((cell, column) => cell.padEnd(widths[column]))
        .join(COLUMN_GAP)
        .trimEnd()
    )
    .join('\n');
}

function renderRow(account: SeededAccount): string[] {
  const known = STANDARD_SEED_ACCOUNTS.find(
    candidate => candidate.email === account.email
  );

  return [
    account.email,
    // An account the profile does not define cannot be logged into from this
    // report; say so rather than printing a blank cell.
    known?.password ?? 'unknown',
    account.admin ? 'admin' : 'user',
    account.created ? 'created' : 'existing',
  ];
}

function accounts(count: number): string {
  return count === 1 ? '1 account' : `${count} accounts`;
}

function summarize(created: number, total: number): string {
  if (created === 0) {
    return `No accounts created, all ${total} already existed.`;
  }

  if (created === total) {
    return `${accounts(total)} created.`;
  }

  return `${accounts(created)} created, ${total - created} already existed.`;
}

/**
 * Formats the outcome of the standard seed profile for the terminal.
 *
 * The credentials are printed in full on every run — including re-runs, where
 * nothing was created — because the point of the fixed profile is that a
 * developer can copy a working login straight out of the command's output.
 */
export function formatStandardSeedReport(result: StandardSeedResult): string {
  const table = renderTable([[...COLUMNS], ...result.accounts.map(renderRow)]);

  return `
Standard seed profile

${table}

${summarize(result.created, result.accounts.length)}
Sign in with these credentials. They are for local development only, never seed them into a production database.
`;
}

/**
 * Formats a refused standard seed run for the terminal.
 *
 * The refusal notice supplies the verdict and its evidence — every blocking
 * setting named with the value it actually holds, and what unsetting it would
 * allow. This block wraps that in the state of the run, which the notice alone
 * cannot report: the database is untouched, so nothing needs undoing, and the
 * whole command can simply be repeated once the settings are gone.
 *
 * `affine setup` is named rather than the seed script because setup is the
 * documented way into the standard profile, and the step it stopped on is the
 * last one — there is nothing left to resume past.
 */
export function formatSeedRefusalReport(
  signals: readonly ProductionSignal[]
): string {
  return `
Standard seed profile — not run

${formatProductionRefusal(signals)}

Nothing was written to the database. Clear the settings listed above, then run \`yarn affine setup\` again.
`;
}
