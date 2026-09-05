import { hash } from '@node-rs/argon2';
import type { PrismaClient, User } from '@prisma/client';

// Imported from the leaf module rather than the `../models` barrel: the barrel
// pulls in the whole Nest DI layer (and through it the native addon), which a
// plain seed script neither has nor needs.
import { FeatureConfigs, type UserFeatureName } from '../models/common';

/**
 * The standard seed profile: a fixed set of accounts every local environment
 * gets, so documentation can name real, loginable credentials instead of
 * telling developers to copy whatever a random seed printed.
 *
 * These credentials are intentionally public and intentionally weak. They are
 * development fixtures, not secrets, and {@link seedStandardProfile} refuses to
 * run when `NODE_ENV=production` so they can never reach a real deployment.
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
 * Seed the fixed local development accounts.
 *
 * Idempotent: accounts are matched by email, and existing rows are never
 * modified, so running this against a populated database is a no-op.
 *
 * @throws {Error} When running with `NODE_ENV=production`.
 */
export async function seedStandardProfile(
  db: PrismaClient
): Promise<StandardSeedResult> {
  if (env.prod) {
    throw new Error(
      'The standard seed profile creates accounts with publicly known passwords and must never run in production.'
    );
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
