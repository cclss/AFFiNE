import { verify } from '@node-rs/argon2';
import type { PrismaClient } from '@prisma/client';
import test from 'ava';

import { Env } from '../../env';
import {
  seedStandardProfile,
  STANDARD_SEED_ADMIN,
  STANDARD_SEED_USER,
} from '../standard';

interface FakeUserRow {
  id: string;
  email: string;
  name: string;
  password: string | null;
  emailVerifiedAt: Date | null;
  registered: boolean;
}

interface FakeUserFeatureRow {
  id: number;
  userId: string;
  name: string;
  type: number;
  reason: string;
  activated: boolean;
}

/**
 * In-memory stand-in for the pieces of prisma the seed touches. Keeps the
 * contract (find by email, insert once) verifiable without a live database.
 */
function createFakeDb() {
  const users: FakeUserRow[] = [];
  const userFeatures: FakeUserFeatureRow[] = [];

  const db = {
    user: {
      findUnique: ({ where }: { where: { email: string } }) =>
        Promise.resolve(users.find(row => row.email === where.email) ?? null),
      create: ({ data }: { data: Partial<FakeUserRow> }) => {
        if (users.some(row => row.email === data.email)) {
          throw new Error(`Unique constraint failed on email ${data.email}`);
        }
        const row: FakeUserRow = {
          id: `user-${users.length + 1}`,
          email: '',
          name: '',
          password: null,
          emailVerifiedAt: null,
          registered: true,
          ...data,
        };
        users.push(row);
        return Promise.resolve(row);
      },
    },
    userFeature: {
      findFirst: ({
        where,
      }: {
        where: { userId: string; name: string; activated: boolean };
      }) =>
        Promise.resolve(
          userFeatures.find(
            feature =>
              feature.userId === where.userId &&
              feature.name === where.name &&
              feature.activated === where.activated
          ) ?? null
        ),
      create: ({ data }: { data: Partial<FakeUserFeatureRow> }) => {
        const row: FakeUserFeatureRow = {
          id: userFeatures.length + 1,
          userId: '',
          name: '',
          type: 0,
          reason: '',
          activated: false,
          ...data,
        };
        userFeatures.push(row);
        return Promise.resolve(row);
      },
    },
  };

  return {
    users,
    userFeatures,
    client: db as unknown as PrismaClient,
  };
}

test.serial(
  'should create the standard accounts on an empty database',
  async t => {
    const db = createFakeDb();

    const result = await seedStandardProfile(db.client);

    t.is(result.created, 2);
    t.is(db.users.length, 2);
    t.deepEqual(
      db.users.map(row => row.email),
      [STANDARD_SEED_USER.email, STANDARD_SEED_ADMIN.email]
    );
    t.deepEqual(
      result.accounts.map(account => account.admin),
      [false, true]
    );
  }
);

test.serial(
  'should store the documented password as a verifiable hash',
  async t => {
    const db = createFakeDb();

    await seedStandardProfile(db.client);

    const seeded = db.users.find(row => row.email === STANDARD_SEED_USER.email);

    t.truthy(seeded?.password);
    t.not(seeded?.password, STANDARD_SEED_USER.password);
    t.true(await verify(seeded?.password ?? '', STANDARD_SEED_USER.password));
  }
);

test.serial(
  'should grant the administrator feature to the admin account only',
  async t => {
    const db = createFakeDb();

    await seedStandardProfile(db.client);

    const admin = db.users.find(row => row.email === STANDARD_SEED_ADMIN.email);

    t.is(db.userFeatures.length, 1);
    t.is(db.userFeatures[0].userId, admin?.id ?? '');
    t.is(db.userFeatures[0].name, 'administrator');
    t.true(db.userFeatures[0].activated);
  }
);

test.serial('should not create duplicates when run again', async t => {
  const db = createFakeDb();

  await seedStandardProfile(db.client);
  const second = await seedStandardProfile(db.client);

  t.is(second.created, 0);
  t.is(db.users.length, 2);
  t.is(db.userFeatures.length, 1);
  t.deepEqual(
    second.accounts.map(account => account.created),
    [false, false]
  );
});

test.serial('should refuse to run in production', async t => {
  const db = createFakeDb();
  const originalEnv = globalThis.env;
  const originalNodeEnv = process.env.NODE_ENV;

  process.env.NODE_ENV = 'production';
  globalThis.env = new Env();

  try {
    await t.throwsAsync(seedStandardProfile(db.client), {
      message: /must never run in production/,
    });
  } finally {
    globalThis.env = originalEnv;
    process.env.NODE_ENV = originalNodeEnv;
  }

  t.is(db.users.length, 0);
});
