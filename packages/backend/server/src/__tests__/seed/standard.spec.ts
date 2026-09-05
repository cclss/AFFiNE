import { Test, TestingModule } from '@nestjs/testing';
import { verify } from '@node-rs/argon2';
import { PrismaClient } from '@prisma/client';
import ava, { TestFn } from 'ava';

import {
  seedStandardProfile,
  STANDARD_SEED_ADMIN,
  STANDARD_SEED_USER,
} from '../../seed/standard';
// Imported from the leaf module rather than the `../utils` barrel: the barrel
// re-exports the Nest testing-module helpers, which drag in `ModelsModule` and
// through it the native addon. The seed runs against a bare `PrismaClient`
// (see `src/seed/index.ts`), so it is tested at that same boundary.
import { initTestingDB } from '../utils/utils';

interface Context {
  module: TestingModule;
  db: PrismaClient;
}

const test = ava as TestFn<Context>;

async function countAdministrators(db: PrismaClient) {
  return await db.userFeature.count({
    where: { name: 'administrator', activated: true },
  });
}

test.before(async t => {
  const db = new PrismaClient();
  t.context.db = db;
  t.context.module = await Test.createTestingModule({
    providers: [{ provide: PrismaClient, useValue: db }],
  }).compile();
});

test.beforeEach(async t => {
  await initTestingDB(t.context.module);
});

test.after.always(async t => {
  await t.context.module?.close();
  await t.context.db?.$disconnect();
});

test('should seed exactly one user and one administrator', async t => {
  const { db } = t.context;

  const result = await seedStandardProfile(db);

  t.is(result.created, 2);
  t.is(await db.user.count(), 2);
  t.is(await countAdministrators(db), 1);

  const admin = await db.user.findUnique({
    where: { email: STANDARD_SEED_ADMIN.email },
  });
  t.truthy(admin);
  t.is(await countAdministrators(db), 1);
  t.is(
    (await db.userFeature.findFirst({ where: { name: 'administrator' } }))
      ?.userId,
    admin?.id
  );
});

test('should keep the account and feature counts stable when run again', async t => {
  const { db } = t.context;

  await seedStandardProfile(db);
  const before = await db.user.findMany({
    orderBy: { email: 'asc' },
    select: { id: true, email: true },
  });

  const rerun = await seedStandardProfile(db);

  t.is(rerun.created, 0);
  t.true(rerun.accounts.every(account => !account.created));
  t.is(await db.user.count(), 2);
  t.is(await countAdministrators(db), 1);
  // Same rows, not recreated ones: a delete-and-reinsert would keep the counts
  // right while silently invalidating every session and document owned by the
  // previous user id.
  t.deepEqual(
    await db.user.findMany({
      orderBy: { email: 'asc' },
      select: { id: true, email: true },
    }),
    before
  );
});

test('should store the documented passwords as verifiable hashes', async t => {
  const { db } = t.context;

  await seedStandardProfile(db);
  await seedStandardProfile(db);

  for (const account of [STANDARD_SEED_USER, STANDARD_SEED_ADMIN]) {
    const user = await db.user.findUnique({
      where: { email: account.email },
    });

    t.truthy(user?.password);
    t.true(
      await verify(user!.password!, account.password),
      `${account.email} should accept the documented password`
    );
    t.false(
      await verify(user!.password!, `${account.password}-wrong`),
      `${account.email} should reject anything else`
    );
  }
});
