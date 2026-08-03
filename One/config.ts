import path from 'node:path';
import { defineConfig } from 'prisma/config';

/**
 * Prisma is used here ONLY as a typed query builder.
 *
 * Schema management is done with the raw SQL migrations in prisma/migrations,
 * because the security model depends on constructs a Prisma datamodel cannot
 * express: partial unique indexes, a generated column inside a composite foreign
 * key, table partitioning, RLS policies, and column-level grants.
 *
 *   USE     npm run db:migrate    -> prisma migrate deploy (applies SQL verbatim)
 *   USE     npm run prisma:generate
 *   BLOCKED prisma migrate dev / migrate reset / db push
 *
 * The block is enforced by tools/prisma-guard.mjs, not by convention — either of
 * those commands would silently drop the constructs above.
 */
export default defineConfig({
  schema: path.join('prisma', 'schema.prisma'),
  migrations: {
    path: path.join('prisma', 'migrations'),
    seed: 'tsx prisma/seed.ts',
  },
});
