#!/usr/bin/env node
/**
 * The one command a fresh clone needs: `yarn setup`.
 *
 * Installs workspace dependencies, then hands over to `affine setup`, which
 * applies the database migrations and seeds the standard accounts.
 *
 * This script runs *before* `node_modules` exists, so it imports nothing but
 * `node:*` builtins. No chalk, no workspace logger, no argument parser.
 */
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const TAG = 'bootstrap';

/**
 * The colours the repo's terminal output uses, as raw escape sequences because
 * chalk is not installed yet. Notice is blue, success is green, danger is the
 * light red on near-black that the workspace logger prints errors in.
 */
const COLOR = {
  notice: '\x1b[34m',
  success: '\x1b[32m',
  danger: '\x1b[48;2;37;2;1m\x1b[38;2;239;135;132m',
};

const RESET = '\x1b[0m';

/**
 * Output that cannot show colour is written plain — never approximated with a
 * nearer colour — so a log pasted out of a pipe reads as ordinary text.
 */
function colorize(stream, color, line) {
  const usable = stream.isTTY && !process.env.NO_COLOR;

  return usable ? `${color}${line}${RESET}` : line;
}

function write(stream, color, message) {
  stream.write(`${colorize(stream, color, `[${TAG}] ${message}`)}\n`);
}

const notice = message => write(process.stdout, COLOR.notice, message);
const success = message => write(process.stdout, COLOR.success, message);
const danger = message => write(process.stderr, COLOR.danger, message);

/**
 * The yarn release checked into the repo, resolved from `.yarnrc.yml`.
 *
 * A fresh clone is guaranteed to have Node — the repo pins it — but not yarn,
 * and a globally installed yarn may be the 1.x line, which cannot run this
 * workspace. The pinned release runs on Node alone, so it is preferred over
 * whatever `yarn` happens to be on PATH.
 */
function yarnRelease() {
  const rc = join(ROOT, '.yarnrc.yml');

  if (!existsSync(rc)) {
    return null;
  }

  const declared = readFileSync(rc, 'utf8').match(
    /^yarnPath:[^\S\n]*"?([^"\n]+?)"?[^\S\n]*$/m
  );

  if (!declared) {
    return null;
  }

  const release = resolve(ROOT, declared[1]);

  return existsSync(release) ? release : null;
}

const RELEASE = yarnRelease();

/**
 * Builds the spawn arguments for a yarn invocation.
 *
 * Falls back to `yarn` on PATH for the day the release stops being vendored.
 * On Windows that name resolves to `yarn.cmd`, which Node refuses to spawn
 * without a shell.
 */
function yarnCommand(args) {
  return RELEASE
    ? { file: process.execPath, args: [RELEASE, ...args], shell: false }
    : { file: 'yarn', args, shell: process.platform === 'win32' };
}

/**
 * The ordered path from a fresh clone to a working local environment.
 *
 * Both steps are safe to repeat. `yarn install` reconciles against the
 * lockfile, and `affine setup` applies only pending migrations and matches
 * seeded accounts by email, so a second run on a populated database brings it
 * up to date instead of failing.
 */
const STEPS = [
  {
    name: 'Dependencies',
    intent: 'Install workspace dependencies',
    command: yarnCommand(['install']),
    retry: 'yarn install',
  },
  {
    name: 'Local environment',
    intent: 'Apply database migrations and seed the standard accounts',
    command: yarnCommand(['affine', 'setup']),
    retry: 'yarn affine setup',
  },
];

/**
 * Runs a step's command, letting its output through untouched.
 *
 * `stdio: 'inherit'` is the point: the child owns its own lines, they arrive
 * live rather than in a lump at the end, and this script never re-tags or
 * rewrites them.
 *
 * Resolves with the exit code. Rejects only when the command could not be run
 * at all.
 */
function run({ file, args, shell }) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(file, args, { cwd: ROOT, stdio: 'inherit', shell });

    child.on('error', rejectPromise);
    child.on('close', (code, signal) => {
      if (signal) {
        rejectPromise(new Error(`terminated by signal ${signal}`));
      } else {
        // A null code with no signal should not happen; treat it as failure
        // rather than silently reporting success.
        resolvePromise(code ?? 1);
      }
    });
  });
}

function position(index) {
  return `${index + 1}/${STEPS.length}`;
}

/**
 * Names the step that failed and how to retry it.
 *
 * The step's own outcome line is always written, even though the child has
 * usually already said something about the failure, so the log shows which
 * layer stopped and not just the innermost error.
 */
function reportFailure(step, at, reason) {
  danger(`Step ${at} ${step.name}: failed`);

  if (reason) {
    danger(`Could not run \`${step.retry}\`: ${reason}`);
  }

  danger(
    `Setup failed at step ${at} ${step.name}. Fix the error above and rerun \`yarn setup\`, or retry this step alone with \`${step.retry}\`.`
  );
}

async function bootstrap() {
  for (const [index, step] of STEPS.entries()) {
    const at = position(index);

    notice(`Step ${at} ${step.name}: ${step.intent}`);

    let code;

    try {
      code = await run(step.command);
    } catch (error) {
      reportFailure(step, at, error.message);
      return 1;
    }

    if (code !== 0) {
      reportFailure(step, at);
      return code;
    }

    success(`Step ${at} ${step.name}: done`);
  }

  success('Setup complete. Sign in with the credentials printed above.');

  return 0;
}

// Set rather than passed to `process.exit`, so the lines written above are
// flushed before the process ends.
process.exitCode = await bootstrap();
