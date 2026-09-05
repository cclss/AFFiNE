import { PrismaClient } from '@prisma/client';
import ava, { TestFn } from 'ava';
import Sinon from 'sinon';

import { Mockers } from '../../__tests__/mocks';
import { createTestingModule, type TestingModule } from '../../__tests__/utils';
import { Models } from '../../models';
import {
  seededFollowUpNotice,
  seededNotice,
  skippedNotice,
  STANDARD_SEED_ADMIN,
  StandardSeedCommand,
} from '../commands/standard-seed';

interface CapturedLog {
  logs: string[];
  warns: string[];
}

interface Context {
  module: TestingModule;
  db: PrismaClient;
  models: Models;
  command: StandardSeedCommand;
  captured: CapturedLog;
}

const test = ava as TestFn<Context>;

test.before(async t => {
  t.context.module = await createTestingModule({
    providers: [StandardSeedCommand],
  });
  t.context.db = t.context.module.get(PrismaClient);
  t.context.models = t.context.module.get(Models);
  t.context.command = t.context.module.get(StandardSeedCommand);
});

test.beforeEach(async t => {
  await t.context.module.initTestingDB();

  // The notices are the deliverable as much as the row is: a bootstrap step
  // that creates nothing has nothing else to show for itself.
  const captured: CapturedLog = { logs: [], warns: [] };
  Sinon.stub(t.context.command.logger, 'log').callsFake((message: any) => {
    captured.logs.push(String(message));
  });
  Sinon.stub(t.context.command.logger, 'warn').callsFake((message: any) => {
    captured.warns.push(String(message));
  });
  t.context.captured = captured;
});

test.afterEach.always(() => {
  Sinon.restore();
});

test.after.always(async t => {
  await t.context.module.close();
});

test('creates the standard administrator when the database has no users', async t => {
  await t.context.command.execute();

  const user = await t.context.models.user.getUserByEmail(
    STANDARD_SEED_ADMIN.email
  );

  t.truthy(user);
  t.is(user?.name, STANDARD_SEED_ADMIN.name);
  t.true(user?.registered);
  t.is(await t.context.models.user.count(), 1);
  t.true(
    await t.context.models.userFeature.has(user!.id, 'administrator'),
    'the seeded account must be able to reach /admin'
  );

  t.deepEqual(t.context.captured.logs, [
    seededNotice(STANDARD_SEED_ADMIN.email),
  ]);
  t.deepEqual(t.context.captured.warns, [seededFollowUpNotice()]);
});

test('the seeded administrator can sign in with the documented password', async t => {
  await t.context.command.execute();

  const user = await t.context.models.user.signIn(
    STANDARD_SEED_ADMIN.email,
    STANDARD_SEED_ADMIN.password
  );

  t.is(user.email, STANDARD_SEED_ADMIN.email);
});

test('a second run creates nothing and says why', async t => {
  await t.context.command.execute();

  const before = await t.context.db.user.findMany();
  const featuresBefore = await t.context.db.userFeature.findMany();
  t.context.captured.logs.length = 0;
  t.context.captured.warns.length = 0;

  await t.notThrowsAsync(t.context.command.execute());

  t.deepEqual(
    await t.context.db.user.findMany(),
    before,
    'the account the first run created must survive the second untouched'
  );
  t.deepEqual(await t.context.db.userFeature.findMany(), featuresBefore);

  t.deepEqual(t.context.captured.logs, [skippedNotice(1)]);
  t.deepEqual(t.context.captured.warns, []);
});

test('skips when the database holds users the seed did not create', async t => {
  await t.context.module.create(Mockers.User, { email: 'someone@affine.pro' });
  await t.context.module.create(Mockers.User, {
    email: 'someone-else@affine.pro',
  });

  await t.notThrowsAsync(t.context.command.execute());

  t.is(await t.context.models.user.count(), 2);
  t.falsy(
    await t.context.models.user.getUserByEmail(STANDARD_SEED_ADMIN.email),
    'a server somebody else set up must not gain an account it never asked for'
  );

  t.deepEqual(t.context.captured.logs, [skippedNotice(2)]);
  t.deepEqual(t.context.captured.warns, []);
});
