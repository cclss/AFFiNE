import { verify } from '@node-rs/argon2';
import type { PrismaClient } from '@prisma/client';
import test from 'ava';

import {
  applyLocalSeedDefaults,
  detectProductionSignals,
} from '../environment';
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

/**
 * Runs `fn` with `overrides` applied to the real environment, then puts the
 * environment back exactly as it was — including variables that were unset,
 * which the guard reads as "nobody configured this box".
 */
async function withEnv(
  overrides: Record<string, string | undefined>,
  fn: () => Promise<void>
) {
  const previous = Object.keys(overrides).map(
    name => [name, process.env[name]] as const
  );

  const apply = (
    entries: readonly (readonly [string, string | undefined])[]
  ) => {
    for (const [name, value] of entries) {
      if (value === undefined) {
        delete process.env[name];
      } else {
        process.env[name] = value;
      }
    }
  };

  apply(Object.entries(overrides));

  try {
    await fn();
  } finally {
    apply(previous);
  }
}

test.serial('should refuse to seed when NODE_ENV names production', async t => {
  const db = createFakeDb();

  await withEnv({ NODE_ENV: 'production', AFFINE_ENV: undefined }, async () => {
    const error = await t.throwsAsync(seedStandardProfile(db.client));

    t.regex(error?.message ?? '', /NODE_ENV=production/);
    t.regex(error?.message ?? '', /publicly known passwords/);
  });

  t.is(db.users.length, 0);
  t.is(db.userFeatures.length, 0);
});

for (const namespace of ['production', 'beta']) {
  test.serial(
    `should refuse to seed when AFFINE_ENV names the deployed ${namespace} namespace`,
    async t => {
      const db = createFakeDb();

      // A development NODE_ENV must not clear a deployed namespace: the seed
      // script itself used to set exactly this value on every run.
      await withEnv(
        { NODE_ENV: 'development', AFFINE_ENV: namespace },
        async () => {
          const error = await t.throwsAsync(seedStandardProfile(db.client));

          t.regex(error?.message ?? '', new RegExp(`AFFINE_ENV=${namespace}`));
        }
      );

      t.is(db.users.length, 0);
      t.is(db.userFeatures.length, 0);
    }
  );
}

test.serial(
  'should name every blocking signal, not just the first',
  async t => {
    const db = createFakeDb();

    await withEnv(
      { NODE_ENV: 'production', AFFINE_ENV: 'production' },
      async () => {
        const error = await t.throwsAsync(seedStandardProfile(db.client));

        t.regex(error?.message ?? '', /NODE_ENV=production/);
        t.regex(error?.message ?? '', /AFFINE_ENV=production/);
      }
    );

    t.is(db.users.length, 0);
  }
);

test.serial(
  'should seed a machine that names no environment at all',
  async t => {
    const db = createFakeDb();

    await withEnv({ NODE_ENV: undefined, AFFINE_ENV: undefined }, async () => {
      const result = await seedStandardProfile(db.client);

      t.is(result.created, 2);
    });

    t.is(db.users.length, 2);
  }
);

test('should default an unset NODE_ENV to development', t => {
  const environment: NodeJS.ProcessEnv = {};

  applyLocalSeedDefaults(environment);

  t.is(environment.NODE_ENV, 'development');
  t.deepEqual(detectProductionSignals(environment), []);
});

test('should not let the local default disarm a stated environment', t => {
  const environment: NodeJS.ProcessEnv = { NODE_ENV: 'production' };

  applyLocalSeedDefaults(environment);

  t.is(environment.NODE_ENV, 'production');
  t.deepEqual(
    detectProductionSignals(environment).map(signal => signal.name),
    ['NODE_ENV']
  );
});
