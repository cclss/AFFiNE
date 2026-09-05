import type { PackageName } from '@affine-tools/utils/workspace';

import { Option, PackageCommand } from './command';
import { defaultTargetNotice, unknownTargetNotice } from './notice';
import { DEFAULT_PACKAGE, resolveTarget } from './target';

export class BuildCommand extends PackageCommand {
  static override paths = [['build'], ['b']];

  // `--package` is optional here, unlike the rest of `PackageCommand`: a bare
  // `yarn build` has to build something rather than die with clipanion's
  // "Unknown Syntax Error: Command not found".
  //
  // The inherited literal-union validator is dropped on purpose. Its rejection
  // message enumerates every workspace package and alias — hundreds of entries —
  // which is not something a human reads. The target is validated against the
  // workspace below instead, and answered with a curated list.
  protected override packageNameOrAlias = Option.String('--package,-p', {
    description: `The package name or alias to build. Defaults to ${DEFAULT_PACKAGE}.`,
  });

  /** The resolved target. Unlike the base getter, this does not assert existence. */
  override get package(): PackageName {
    return resolveTarget(this.packageNameOrAlias);
  }

  async execute() {
    const given = this.packageNameOrAlias?.trim();
    const target = this.package;

    if (!this.workspace.tryGetPackage(target)) {
      this.logger.error(unknownTargetNotice(given || target));
      return 1;
    }

    if (!given) {
      this.logger.info(defaultTargetNotice(target));
    }

    const args: string[] = [];

    if (this.deps) {
      args.push('--deps', '--wait-deps');
    }

    args.push(target, 'build');

    // NOTE: the nested run's exit code is deliberately left as-is (pre-existing
    // behaviour of this command); only the guidance path above sets one.
    await this.cli.run(args);

    return;
  }
}
