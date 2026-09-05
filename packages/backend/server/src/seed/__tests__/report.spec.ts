import test from 'ava';

import { formatStandardSeedReport } from '../report';
import {
  type SeededAccount,
  STANDARD_SEED_ADMIN,
  STANDARD_SEED_USER,
  type StandardSeedResult,
} from '../standard';

function seeded(
  overrides: Partial<SeededAccount> & Pick<SeededAccount, 'email'>
): SeededAccount {
  return {
    name: 'Dev User',
    admin: false,
    created: true,
    ...overrides,
  };
}

function firstRun(): StandardSeedResult {
  return {
    accounts: [
      seeded({ email: STANDARD_SEED_USER.email }),
      seeded({
        email: STANDARD_SEED_ADMIN.email,
        name: STANDARD_SEED_ADMIN.name,
        admin: true,
      }),
    ],
    created: 2,
  };
}

function reRun(): StandardSeedResult {
  return {
    accounts: firstRun().accounts.map(account => ({
      ...account,
      created: false,
    })),
    created: 0,
  };
}

/** The header row plus every account row, in order. */
function table(report: string): string[] {
  const lines = report.split('\n');
  const header = lines.findIndex(line => line.startsWith('EMAIL'));

  return lines.slice(header, header + 3);
}

/** Start column of every cell on a line. Cells never contain spaces. */
function cellOffsets(line: string): number[] {
  const offsets: number[] = [];

  for (let index = 0; index < line.length; index++) {
    if (line[index] !== ' ' && (index === 0 || line[index - 1] === ' ')) {
      offsets.push(index);
    }
  }

  return offsets;
}

test('prints one row per account with its documented credentials', t => {
  const [header, user, admin] = table(formatStandardSeedReport(firstRun()));

  t.deepEqual(header.split(/\s+/), ['EMAIL', 'PASSWORD', 'ROLE', 'STATUS']);
  t.deepEqual(user.split(/\s+/), [
    STANDARD_SEED_USER.email,
    STANDARD_SEED_USER.password,
    'user',
    'created',
  ]);
  t.deepEqual(admin.split(/\s+/), [
    STANDARD_SEED_ADMIN.email,
    STANDARD_SEED_ADMIN.password,
    'admin',
    'created',
  ]);
});

test('aligns every column to a shared boundary', t => {
  const [header, ...rows] = table(formatStandardSeedReport(firstRun()));
  const expected = cellOffsets(header);

  t.is(expected.length, 4);
  for (const row of rows) {
    t.deepEqual(cellOffsets(row), expected);
  }
});

test('repeats the same credentials on a re-run, only the status changes', t => {
  const [, ...first] = table(formatStandardSeedReport(firstRun()));
  const [, ...again] = table(formatStandardSeedReport(reRun()));

  t.deepEqual(
    again.map(row => row.split(/\s+/).slice(0, 3)),
    first.map(row => row.split(/\s+/).slice(0, 3))
  );
  t.deepEqual(
    again.map(row => row.split(/\s+/)[3]),
    ['existing', 'existing']
  );
});

test('summarizes what the run did', t => {
  t.true(formatStandardSeedReport(firstRun()).includes('2 accounts created.'));
  t.true(
    formatStandardSeedReport(reRun()).includes(
      'No accounts created, all 2 already existed.'
    )
  );

  const partial: StandardSeedResult = {
    accounts: [
      seeded({ email: STANDARD_SEED_USER.email, created: false }),
      seeded({ email: STANDARD_SEED_ADMIN.email, admin: true }),
    ],
    created: 1,
  };

  t.true(
    formatStandardSeedReport(partial).includes(
      '1 account created, 1 already existed.'
    )
  );
});

test('warns that the credentials are local only', t => {
  t.regex(
    formatStandardSeedReport(firstRun()),
    /local development only, never seed them into a production database/
  );
});
