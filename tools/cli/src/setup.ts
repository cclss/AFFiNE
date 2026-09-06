import { Command, Option } from './command';

export interface SetupStep {
  /**
   * Short name of what the step brings up. Printed while the step runs and
   * named again in the failure message, so it has to read well in both.
   */
  name: string;
  /** What the step does, in the imperative. Printed in the plan. */
  description: string;
  /**
   * Arguments handed to the `affine run` command, which resolves them against
   * the target package's scripts. Setup never shells out on its own.
   */
  args: string[];
}

/**
 * The one ordered path from a fresh clone to a working local environment.
 *
 * Every step is safe to repeat: `migrate deploy` applies only pending
 * migrations (and, unlike `migrate dev`, never offers to reset a populated
 * database), the data migration runner skips what it has already run, and the
 * standard seed profile matches accounts by email. Running setup against a
 * database that is already up to date is a no-op, not an error.
 */
export const SETUP_STEPS: readonly SetupStep[] = [
  {
    name: 'Database schema',
    description: 'Apply pending database migrations',
    args: ['@affine/server', 'prisma', 'migrate', 'deploy'],
  },
  {
    name: 'Data migration',
    description: 'Run pending data migrations',
    args: ['@affine/server', 'data-migration', 'run'],
  },
  {
    name: 'Standard seed',
    description: 'Create the fixed local development accounts',
    args: ['@affine/server', 'seed:standard'],
  },
];

const COLUMNS = ['STEP', 'TASK', 'COMMAND'] as const;

/**
 * Minimum gap between two aligned columns, matching the seed report's table.
 */
const COLUMN_GAP = '  ';

/** The command a developer would type to run a single step by hand. */
function commandOf(step: SetupStep): string {
  return `affine ${step.args.join(' ')}`;
}

/** `2/3` — the position of a step, as shown to the developer. */
function position(index: number, total: number): string {
  return `${index + 1}/${total}`;
}

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

/**
 * What a thrown cause has to say for itself, as a clause. Non-errors are
 * stringified rather than dropped: a rejection carrying a plain value is still
 * more than the developer would otherwise be told.
 */
function describeCause(cause: unknown): string {
  const message = (
    cause instanceof Error ? cause.message : String(cause)
  ).trim();

  return message.length ? message : 'the step failed without a message';
}

/**
 * Formats the ordered steps for `--dry-run`.
 *
 * The plan states plainly that nothing ran, so a dry run can never be mistaken
 * for a completed setup.
 */
export function formatSetupPlan(steps: readonly SetupStep[]): string {
  const table = renderTable([
    [...COLUMNS],
    ...steps.map((step, index) => [
      position(index, steps.length),
      step.description,
      commandOf(step),
    ]),
  ]);

  return `
Setup plan

${table}

${steps.length} steps, nothing executed. Run \`yarn affine setup\` to apply them.
`;
}

export class SetupCommand extends Command {
  static override paths = [['setup']];

  static override usage = Command.Usage({
    description: 'Bring a local environment up to a working state',
    details: `
      Runs the local bootstrap steps in order: database migrations, data
      migrations, then the standard seed profile.

      Every step is safe to repeat, so running setup against a database that
      already holds data brings it up to date instead of failing.
    `,
    examples: [
      ['Set up the local environment', '$0 setup'],
      ['Print the steps without running them', '$0 setup --dry-run'],
    ],
  });

  dryRun = Option.Boolean('--dry-run', false, {
    description: 'Print the ordered steps without running them',
  });

  async execute() {
    if (this.dryRun) {
      // Written straight to stdout rather than through the logger: the plan is
      // a block with its own alignment and blank lines, which a per-line tag
      // would break up.
      this.context.stdout.write(formatSetupPlan(SETUP_STEPS));
      return;
    }

    const total = SETUP_STEPS.length;

    for (const [index, step] of SETUP_STEPS.entries()) {
      const at = position(index, total);

      this.logger.info(`Step ${at} ${step.name}: ${step.description}`);

      await this.runStep(step, at);

      this.logger.success(`Step ${at} ${step.name}: done`);
    }

    this.logger.success(
      'Setup complete. Sign in with the credentials printed above.'
    );
  }

  private async runStep(step: SetupStep, at: string) {
    let exitCode: number;

    try {
      exitCode = await this.cli.run(step.args);
    } catch (cause) {
      // The step threw before it could report for itself, so this error is the
      // only account of what went wrong.
      throw this.stepFailure(step, at, { cause });
    }

    if (exitCode !== 0) {
      // The step already printed why it stopped — a refused seed prints the
      // settings that blocked it — and that output stands as the reason. Adding
      // nothing here keeps it the last word on the subject.
      throw this.stepFailure(step, at);
    }
  }

  /**
   * Names the step that failed and the command to retry it with. Setup stops
   * here: a later step run on a half-migrated database would fail in a way
   * that no longer points at the actual cause.
   *
   * A `cause`, when there is one, is restated in the message rather than only
   * attached to it. The error goes to clipanion's formatter, which prints the
   * message and the stack and drops `cause` entirely — attaching it alone would
   * lose the very thing the developer needs.
   */
  private stepFailure(step: SetupStep, at: string, thrown?: ErrorOptions) {
    this.logger.error(`Step ${at} ${step.name}: failed`);

    // Absence of `thrown` — not an undefined cause inside it — is what says the
    // step ran and printed its own account of what stopped it. A refused seed
    // prints the settings that blocked it, and pointing at that output beats
    // restating it in weaker words.
    const reason = thrown
      ? `${describeCause(thrown.cause)}. Fix it and rerun`
      : 'Fix the error above and rerun';

    return new Error(
      `Setup failed at step ${at} ${step.name}. ${reason} \`yarn affine setup\`, or retry this step alone with \`yarn ${commandOf(step)}\`.`,
      thrown
    );
  }
}
