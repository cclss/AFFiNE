import { Injectable, Logger } from '@nestjs/common';

import { Models } from '../../models';

/**
 * The account a freshly bootstrapped self-host server comes up with.
 *
 * These three values are a published default, not a secret: the whole point is
 * that someone who has just built the image can sign in without being handed
 * anything out of band. That is also why the password is spelled the way it is
 * — it reads, in the sign-in form and in the documentation alike, as something
 * that is meant to be replaced.
 *
 * `example.com` is reserved for documentation by RFC 2606, so this address can
 * never collide with a real mailbox, and mail addressed to it goes nowhere.
 */
export const STANDARD_SEED_ADMIN = {
  name: 'Admin',
  email: 'admin@example.com',
  password: 'change-me',
} as const;

/**
 * Recorded against the granted feature so that a later reader can tell an
 * account this command created from one a human created.
 */
export const STANDARD_SEED_REASON = 'standard seed';

/**
 * Notices follow the cli-bootstrap-notice component: one line per outcome,
 * carrying the concrete value the decision was made on, and never carrying a
 * password — container logs are kept by whoever collects them.
 */
export function seededNotice(email: string) {
  return `No users in this database — created the standard administrator ${email}.`;
}

export function seededFollowUpNotice() {
  return `The standard administrator was created with a published default password — sign in at \`/admin\` and change it before this server is reachable by anyone else.`;
}

export function skippedNotice(userCount: number) {
  return `This database already holds ${userCount} user${
    userCount === 1 ? '' : 's'
  } — the standard seed created nothing.`;
}

/**
 * Creates the documented dummy administrator, once.
 *
 * Re-running this is the normal case, not the exceptional one: the command sits
 * on the container's startup path, and a container is restarted over data it
 * has already written far more often than it is started over an empty database.
 * So "a user already exists" is a skip with a line of explanation, never an
 * error — a bootstrap step that fails on the second boot is a bootstrap step
 * that makes the image unrunnable twice.
 *
 * The emptiness test is `user.count() > 0`, which is the same question
 * `ServerService.initialized()` asks and the same one `/api/setup/create-admin-user`
 * refuses on. Any account — administrator or not, disabled or not — means this
 * server has been set up by somebody, and the seed stays out of the way.
 */
@Injectable()
export class StandardSeedCommand {
  logger = new Logger(StandardSeedCommand.name);

  constructor(private readonly models: Models) {}

  async execute(): Promise<void> {
    const userCount = await this.models.user.count();

    if (userCount > 0) {
      this.logger.log(skippedNotice(userCount));
      return;
    }

    const user = await this.models.user.create({
      name: STANDARD_SEED_ADMIN.name,
      email: STANDARD_SEED_ADMIN.email,
      password: STANDARD_SEED_ADMIN.password,
      registered: true,
    });

    // Granting the feature is what makes the account useful; an account without
    // it cannot reach /admin, so a failure here must not leave a half-seeded
    // user behind for the next boot to skip on. The setup controller takes the
    // same precaution for the same reason.
    try {
      await this.models.userFeature.add(
        user.id,
        'administrator',
        STANDARD_SEED_REASON
      );
    } catch (e) {
      await this.models.user.delete(user.id);
      throw e;
    }

    this.logger.log(seededNotice(user.email));
    this.logger.warn(seededFollowUpNotice());
  }
}
