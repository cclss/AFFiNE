// AFFiNE self-host initial setup.
//
// The single entrypoint that brings an arbitrary database up to the state the
// server expects, in the order the server needs it:
//
//   1. config files the server cannot start without   (private.key)
//   2. schema migrations                              (`yarn prisma migrate deploy`)
//   3. data migrations                                (`yarn cli run`)
//   4. the standard administrator                     (`yarn cli standard-seed`)
//
// Every step is conditional on what it finds rather than on "is this the first
// boot", because it is not: scripts/self-host-entrypoint.sh calls this once on
// every container start, on both the in-image and the external database paths,
// and a container is restarted over data it has already written far more often
// than it is started over an empty database. Re-running this is therefore the
// normal case, and each step is written to be a no-op the second time — the
// seed included, which skips as soon as the database holds any user.
//
// Behaviour is covered by scripts/self-host-predeploy.test.sh, which runs this
// script against a stub `yarn` and needs neither a database nor a built bundle.

import { execSync } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import fs from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const SELF_HOST_CONFIG_DIR = `${homedir()}/.affine/config`;

// Notices follow the cli-bootstrap-notice component: one line per step, saying
// what the step did or why it did nothing, and carrying the concrete value the
// decision was made on. This script runs outside Nest, so there is no logger to
// supply the `[name] ` prefix and it is applied here instead — the same way
// scripts/self-host-entrypoint.sh applies its own.
//
// Connection strings, passwords and key material never appear in these lines.
// Container logs are kept by whoever collects them.
const NOTICE_TAG = '[predeploy]';

// One state, one line. Whitespace is collapsed because some of these messages
// carry a command's error output, which arrives with newlines in it — and a
// notice that spans lines stops being greppable next to the ones that do not.
function notice(message) {
  console.log(`${NOTICE_TAG} ${message.replace(/\s+/g, ' ').trim()}`);
}

function generatePrivateKey() {
  const key = generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
  }).privateKey.export({
    type: 'sec1',
    format: 'pem',
  });

  if (key instanceof Buffer) {
    return key.toString('utf-8');
  }

  return key;
}

/**
 * @type {Array<{ to: string; generator: () => string }>}
 */
const files = [{ to: 'private.key', generator: generatePrivateKey }];

function prepare() {
  fs.mkdirSync(SELF_HOST_CONFIG_DIR, { recursive: true });

  for (const { to, generator } of files) {
    const targetFilePath = path.join(SELF_HOST_CONFIG_DIR, to);

    // Generated only when absent. The key signs sessions, so replacing it would
    // sign every user out on a restart — and an operator who mounted this
    // directory as a volume did so precisely to stop that happening.
    if (fs.existsSync(targetFilePath)) {
      notice(
        `Kept the existing \`${to}\` — ${SELF_HOST_CONFIG_DIR} already holds one.`
      );
      continue;
    }

    fs.writeFileSync(targetFilePath, generator(), 'utf-8');
    notice(`Created \`${to}\` — ${SELF_HOST_CONFIG_DIR} did not hold one.`);
  }
}

/**
 * Runs one bootstrap step by handing it to a command, after announcing which
 * command it is. The outcome is not announced here: the command reports it
 * under its own prefix, and predicting it from this side would mean printing
 * one line before the work and a contradicting one after a failure.
 */
function runStep(description, command) {
  notice(`${description} — \`${command}\`.`);
  execSync(command, {
    encoding: 'utf-8',
    env: process.env,
    stdio: 'inherit',
  });
}

function runPrismaMigrations() {
  runStep('Applying schema migrations', 'yarn prisma migrate deploy');
}

function runDataMigrations() {
  runStep('Applying data migrations', 'yarn cli run');
}

/**
 * The last step, and the one that makes a freshly built image usable: without
 * it the server comes up with no users at all and an unauthenticated setup
 * screen. It runs after both migration steps because it writes a row, and the
 * table to hold that row is created by the schema migrations above.
 *
 * It is not guarded here by "does this database look empty". That question is
 * asked inside the command, against the database it is about to write to, in
 * the same transaction-free instant — asking it from out here would be a second
 * answer free to disagree with the first.
 */
function runStandardSeed() {
  runStep('Seeding the standard administrator', 'yarn cli standard-seed');
}

function fixFailedMigrations() {
  const maybeFailedMigrations = [
    '20250521083048_fix_workspace_embedding_chunk_primary_key',
  ];

  for (const migration of maybeFailedMigrations) {
    try {
      execSync(`yarn prisma migrate resolve --rolled-back ${migration}`, {
        encoding: 'utf-8',
        env: process.env,
        stdio: 'pipe',
      });
      notice(
        `Rolled back \`${migration}\` — an earlier run left it in a failed state.`
      );
    } catch (err) {
      if (
        err.message.includes(
          'cannot be rolled back because it is not in a failed state'
        ) ||
        err.message.includes(
          'cannot be rolled back because it was never applied'
        ) ||
        err.message.includes(
          'called markMigrationRolledBack on a database without migrations table'
        )
      ) {
        // Nothing to roll back. This is what every boot after the first looks
        // like, so it is reported and stepped over rather than raised.
        notice(
          `Left \`${migration}\` alone — it is not in a failed state on this database.`
        );
        continue;
      }

      // Any other cause is reported and stepped over too: the rollback is a
      // repair for one known-bad migration, and refusing to boot because the
      // repair was not needed would be the worse failure. `prisma migrate
      // deploy` below still stops on a schema it cannot advance.
      notice(`Could not roll back \`${migration}\` — ${err.message}`);
    }
  }
}

prepare();
fixFailedMigrations();
runPrismaMigrations();
runDataMigrations();
runStandardSeed();
