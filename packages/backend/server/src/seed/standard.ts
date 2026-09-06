import { hash } from '@node-rs/argon2';
import type { PrismaClient, User } from '@prisma/client';

// Imported from the leaf module rather than the `../models` barrel: the barrel
// pulls in the whole Nest DI layer (and through it the native addon), which a
// plain seed script neither has nor needs.
import { FeatureConfigs, type UserFeatureName } from '../models/common';
import {
  detectProductionSignals,
  formatProductionRefusal,
  type ProductionSignal,
} from './environment';

/**
 * The standard seed profile: a fixed set of accounts every local environment
 * gets, so documentation can name real, loginable credentials instead of
 * telling developers to copy whatever a random seed printed.
 *
 * These credentials are intentionally public and intentionally weak. They are
 * development fixtures, not secrets, and {@link seedStandardProfile} refuses to
 * run on any environment configured as a deployed one, so they can never reach
 * a real deployment.
 */
export interface StandardSeedAccount {
  email: string;
  password: string;
  name: string;
  /**
   * User feature granted on creation, if any.
   */
  feature?: UserFeatureName;
}

/** Regular member account. */
export const STANDARD_SEED_USER: StandardSeedAccount = {
  email: 'dev@affine.local',
  password: 'affine-dev',
  name: 'Dev User',
};

/** Administrator account, able to open the admin panel. */
export const STANDARD_SEED_ADMIN: StandardSeedAccount = {
  email: 'admin@affine.local',
  password: 'affine-admin',
  name: 'Dev Admin',
  feature: 'administrator',
};

export const STANDARD_SEED_ACCOUNTS: readonly StandardSeedAccount[] = [
  STANDARD_SEED_USER,
  STANDARD_SEED_ADMIN,
];

const SEED_REASON = 'standard seed profile';

export interface SeededAccount {
  email: string;
  name: string;
  admin: boolean;
  /**
   * `false` when the account already existed and was left untouched.
   */
  created: boolean;
}

export interface StandardSeedResult {
  accounts: SeededAccount[];
  /**
   * Number of accounts created by this run. `0` on a repeated run.
   */
  created: number;
}

/**
 * Raised when the guard finds this environment configured as a deployed one.
 *
 * Carries the signals behind the verdict so the output layer can render the
 * refusal itself, rather than a stack trace whose frames name the line that
 * reported the decision and never the settings that caused it.
 *
 * The message is still the full refusal text. A caller that only ever reads
 * `error.message` — a log line, a generic `catch` — then reports why the run
 * stopped instead of merely that something went wrong.
 */
export class SeedRefusedError extends Error {
  constructor(readonly signals: readonly ProductionSignal[]) {
    super(formatProductionRefusal(signals));
    this.name = 'SeedRefusedError';
  }
}

/**
 * Seed the fixed local development accounts.
 *
 * Idempotent: accounts are matched by email, and existing rows are never
 * modified, so running this against a populated database is a no-op.
 *
 * @throws {SeedRefusedError} When the environment carries any deployment
 * setting. Nothing is written to the database before the check.
 */
export async function seedStandardProfile(
  db: PrismaClient
): Promise<StandardSeedResult> {
  const blocked = detectProductionSignals();

  if (blocked.length) {
    throw new SeedRefusedError(blocked);
  }

  const accounts: SeededAccount[] = [];

  // Sequential on purpose: concurrent inserts of the same account would race on
  // the unique email constraint.
  for (const account of STANDARD_SEED_ACCOUNTS) {
    accounts.push(await seedAccount(db, account));
  }

  return {
    accounts,
    created: accounts.filter(account => account.created).length,
  };
}

async function seedAccount(
  db: PrismaClient,
  account: StandardSeedAccount
): Promise<SeededAccount> {
  let user: User | null = await db.user.findUnique({
    where: { email: account.email },
  });
  const created = !user;

  if (!user) {
    user = await db.user.create({
      data: {
        email: account.email,
        name: account.name,
        password: await hash(account.password),
        // Skip the verification mail round trip; these accounts must be
        // usable right after the seed finishes.
        emailVerifiedAt: new Date(),
        registered: true,
      },
    });
  }

  if (account.feature) {
    await grantFeature(db, user.id, account.feature);
  }

  return {
    email: account.email,
    name: account.name,
    admin: !!account.feature,
    created,
  };
}

async function grantFeature(
  db: PrismaClient,
  userId: string,
  name: UserFeatureName
) {
  const existing = await db.userFeature.findFirst({
    where: { userId, name, activated: true },
  });

  if (existing) {
    return existing;
  }

  return await db.userFeature.create({
    data: {
      userId,
      name,
      type: FeatureConfigs[name].type,
      reason: SEED_REASON,
      activated: true,
    },
  });
}
