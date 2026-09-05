import { AliasToPackage } from '@affine-tools/utils/distribution';
import type { PackageName } from '@affine-tools/utils/workspace';
import { describe, expect, it } from 'vitest';

import {
  DEFAULT_PACKAGE,
  featuredTargets,
  formatTargetList,
  isNonInteractive,
  listAliases,
  listPackages,
  resolveTarget,
} from '../target';

/** A tiny stand-in table, so formatting tests do not depend on the real workspace. */
const fakeAliases = new Map<string, PackageName>([
  ['web', '@affine/web' as PackageName],
  ['gql', '@affine/graphql' as PackageName],
]);

describe('DEFAULT_PACKAGE', () => {
  it('is the web app', () => {
    expect(DEFAULT_PACKAGE).toBe('@affine/web');
  });

  it('is a real target in the alias table', () => {
    expect(listPackages()).toContain(DEFAULT_PACKAGE);
  });
});

describe('resolveTarget', () => {
  it('falls back to the default target when nothing is given', () => {
    expect(resolveTarget()).toBe(DEFAULT_PACKAGE);
    expect(resolveTarget(undefined)).toBe(DEFAULT_PACKAGE);
    expect(resolveTarget(null)).toBe(DEFAULT_PACKAGE);
    expect(resolveTarget('')).toBe(DEFAULT_PACKAGE);
    expect(resolveTarget('   ')).toBe(DEFAULT_PACKAGE);
  });

  it('expands an alias to its package name', () => {
    expect(resolveTarget('gql')).toBe('@affine/graphql');
    expect(resolveTarget('desktop')).toBe('@affine/electron-renderer');
  });

  it('trims surrounding whitespace before looking an alias up', () => {
    expect(resolveTarget('  web  ')).toBe('@affine/web');
  });

  it('passes an unknown name through untouched, leaving validation to the workspace', () => {
    expect(resolveTarget('@affine/nope')).toBe('@affine/nope');
  });

  it('reads from the table it is given', () => {
    expect(resolveTarget('gql', fakeAliases)).toBe('@affine/graphql');
    expect(resolveTarget('admin', fakeAliases)).toBe('admin');
  });
});

describe('featuredTargets', () => {
  const documentedAliases = [
    'web',
    'admin',
    'electron',
    'desktop',
    'renderer',
    'mobile',
    'ios',
    'android',
    'server',
    'gql',
  ];

  it('surfaces every documented alias', () => {
    expect(featuredTargets().map(entry => entry.alias)).toEqual(
      documentedAliases
    );
  });

  it('maps each documented alias to the package AliasToPackage points at', () => {
    for (const { alias, package: pkg } of featuredTargets()) {
      expect(pkg).toBe(AliasToPackage.get(alias));
    }
  });

  it('resolves the aliases the distribution table defines', () => {
    expect(
      Object.fromEntries(featuredTargets().map(e => [e.alias, e.package]))
    ).toEqual({
      web: '@affine/web',
      admin: '@affine/admin',
      electron: '@affine/electron',
      desktop: '@affine/electron-renderer',
      renderer: '@affine/electron-renderer',
      mobile: '@affine/mobile',
      ios: '@affine/ios',
      android: '@affine/android',
      server: '@affine/server',
      gql: '@affine/graphql',
    });
  });

  it('drops curated aliases that the given table does not define', () => {
    expect(featuredTargets(fakeAliases)).toEqual([
      { alias: 'web', package: '@affine/web' },
      { alias: 'gql', package: '@affine/graphql' },
    ]);
  });
});

describe('listAliases', () => {
  it('includes every documented alias', () => {
    const aliases = listAliases();

    for (const alias of [
      'web',
      'admin',
      'electron',
      'desktop',
      'renderer',
      'mobile',
      'ios',
      'android',
      'server',
      'gql',
    ]) {
      expect(aliases).toContain(alias);
    }
  });

  it('is sorted', () => {
    const aliases = listAliases();
    expect(aliases).toEqual([...aliases].sort());
  });
});

describe('listPackages', () => {
  it('deduplicates aliases that share a package', () => {
    const packages = listPackages();
    const rendererCount = packages.filter(
      name => name === '@affine/electron-renderer'
    ).length;

    expect(rendererCount).toBe(1);
  });

  it('is sorted', () => {
    const packages = listPackages();
    expect(packages).toEqual([...packages].sort());
  });
});

describe('formatTargetList', () => {
  it('renders one aligned "alias → package" row per target', () => {
    expect(formatTargetList(fakeAliases)).toBe(
      ['  web → @affine/web', '  gql → @affine/graphql'].join('\n')
    );
  });

  it('pads aliases to a common width so the arrows line up', () => {
    const rows = formatTargetList().split('\n');
    const arrowColumns = new Set(rows.map(row => row.indexOf('→')));

    expect(rows).toHaveLength(featuredTargets().length);
    expect(arrowColumns.size).toBe(1);
  });

  it('honours a custom indent', () => {
    expect(formatTargetList(fakeAliases, { indent: '' })).toBe(
      ['web → @affine/web', 'gql → @affine/graphql'].join('\n')
    );
  });

  it('names every documented alias and its package', () => {
    const list = formatTargetList();

    for (const { alias, package: pkg } of featuredTargets()) {
      expect(list).toContain(alias);
      expect(list).toContain(pkg);
    }
  });

  it('has no trailing newline, so callers own the framing', () => {
    expect(formatTargetList()).not.toMatch(/\n$/);
  });
});

describe('isNonInteractive', () => {
  it('is interactive only with a TTY and no CI flag', () => {
    expect(isNonInteractive({ isTTY: true, env: {} })).toBe(false);
  });

  it('is non-interactive without a TTY', () => {
    expect(isNonInteractive({ isTTY: false, env: {} })).toBe(true);
    expect(isNonInteractive({ isTTY: undefined, env: {} })).toBe(true);
  });

  it('is non-interactive when CI is set, even on a TTY', () => {
    expect(isNonInteractive({ isTTY: true, env: { CI: '1' } })).toBe(true);
    expect(isNonInteractive({ isTTY: true, env: { CI: 'true' } })).toBe(true);
  });

  it('ignores an empty CI variable', () => {
    expect(isNonInteractive({ isTTY: true, env: { CI: '' } })).toBe(false);
  });

  it('falls back to the real process when given nothing', () => {
    expect(typeof isNonInteractive()).toBe('boolean');
  });
});
