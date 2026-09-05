import type { PackageName } from '@affine-tools/utils/workspace';
import { describe, expect, it } from 'vitest';

import {
  defaultTargetNotice,
  PICK_ANOTHER_TARGET,
  unknownTargetNotice,
} from '../notice';
import { DEFAULT_PACKAGE, featuredTargets, listAliases } from '../target';

/** A tiny stand-in table, so the notices do not depend on the real workspace. */
const fakeAliases = new Map<string, PackageName>([
  ['web', '@affine/web' as PackageName],
  ['gql', '@affine/graphql' as PackageName],
]);

describe('defaultTargetNotice', () => {
  it('names the default target it is about to build', () => {
    expect(defaultTargetNotice()).toContain(DEFAULT_PACKAGE);
  });

  it('shows how to pick a different target', () => {
    expect(defaultTargetNotice()).toContain('yarn build -p <target>');
  });

  it('lists the targets that can be picked', () => {
    const notice = defaultTargetNotice();

    for (const { alias, package: pkg } of featuredTargets()) {
      expect(notice).toContain(alias);
      expect(notice).toContain(pkg);
    }
  });

  it('never leaks clipanion syntax-error wording', () => {
    expect(defaultTargetNotice()).not.toMatch(/Unknown Syntax Error/i);
  });

  it('reads the target list from the table it is given', () => {
    const notice = defaultTargetNotice(DEFAULT_PACKAGE, fakeAliases);

    expect(notice).toContain('gql');
    expect(notice).not.toContain('android');
  });

  it('reports the target it was handed, not only the default', () => {
    expect(defaultTargetNotice('@affine/admin' as PackageName)).toContain(
      '@affine/admin'
    );
  });
});

describe('unknownTargetNotice', () => {
  it('quotes back what the user actually typed', () => {
    expect(unknownTargetNotice('wob')).toContain(`'wob'`);
  });

  it('lists the available targets', () => {
    const notice = unknownTargetNotice('wob');

    for (const { alias } of featuredTargets()) {
      expect(notice).toContain(alias);
    }
  });

  it('says that full package names are accepted too', () => {
    const notice = unknownTargetNotice('wob');

    expect(notice).toContain('workspace package name');
    expect(notice).toContain(DEFAULT_PACKAGE);
  });

  it('never leaks clipanion syntax-error wording', () => {
    expect(unknownTargetNotice('wob')).not.toMatch(/Unknown Syntax Error/i);
  });

  it('stays short enough to read — one screen, not the whole alias table', () => {
    const lines = unknownTargetNotice('wob').split('\n');

    expect(lines.length).toBeLessThan(20);
    expect(lines.length).toBeLessThan(listAliases().length);
  });

  it('reads the target list from the table it is given', () => {
    const notice = unknownTargetNotice('wob', fakeAliases);

    expect(notice).toContain('gql');
    expect(notice).not.toContain('android');
  });
});

describe('notice consistency', () => {
  it('points at the same escape hatch in both notices', () => {
    expect(defaultTargetNotice()).toContain(PICK_ANOTHER_TARGET);
    expect(unknownTargetNotice('wob')).toContain(PICK_ANOTHER_TARGET);
  });

  it('emits no blank lines, which the CLI logger would drop', () => {
    for (const notice of [defaultTargetNotice(), unknownTargetNotice('wob')]) {
      expect(notice.split('\n').every(line => line.trim().length > 0)).toBe(
        true
      );
    }
  });
});
