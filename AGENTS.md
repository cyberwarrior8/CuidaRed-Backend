# Repository Guidelines

## Project Structure & Module Organization

JavaScript ESM backend: `src/app.js`/`server.js`, shared `src/config/` and `src/lib/`, feature modules in `src/modules/`, and `tests/*.test.js`. Contracts and database proposals live in `docs/`; applied migrations in `supabase/migrations/`.

Read `CONTEXTO-BACKEND.md` and `PLAN-DESARROLLO-BACKEND.md`. Sources: `../../Docs/`; frontend: `../CuidaRed-Frontend/`. Its connected access and demo are isolated. Keep HTTP handlers, validation, persistence, and tests separate.

## Build, Test, and Development Commands

Use Node.js 24.19+ within major 24; install exact locked dependencies with `npm ci`.

Commands from the backend root:

- `npm run dev` / `npm start` — watched / normal server.
- `npm test` — Vitest/Supertest with intercepted dependencies.
- `npm run lint` / `npm run format:check` — ESLint / Prettier checks.
- `npm run format` — apply formatting.

JavaScript runs directly, without TypeScript compilation. Inspect `git status --short` and `git diff --check`; review untracked files separately.

## Coding Style & Naming Conventions

Use JavaScript, Node.js/Express, Supabase, Zod, ESLint and Prettier with two-space indentation, as confirmed by the user. Do not introduce TypeScript into the backend.

Follow the SRS naming rules: `camelCase` variables/functions, `snake_case` database identifiers, and `kebab-case` filenames/routes. Source headers identify purpose, module, and project copyright. Keep business rules in services and validate inputs and resource permissions on the server.

## Testing Guidelines

Use Vitest/Supertest for backend tests; Playwright covers frontend flows. No coverage threshold is agreed. Trace tests to RF/CU identifiers. Cover authorization, isolation, validated evidence, expiry and idempotency as modules arrive. Remote integration requires database approval; mocks do not certify RLS.

## Commit & Pull Request Guidelines

History contains only `Initial commit`. Use concise imperative subjects. PRs must explain behavior, link requirements/issues, report validation and unresolved decisions, and receive documented review.

**Obtain prior explicit approval before every commit. Never commit to `master`.**

## Security & Context Decisions

V2 rules prevail; retain compatible SRS requirements. Follow the project's documented security guidelines and good practices, especially `../../Docs/Seguridad/` and the SRS. Protect secrets, enforce authorization/RLS, and use synthetic data. Stripe is sandbox-only.

**Do not change database schema, data, permissions, policies, or apply migrations without prior approval.** `DB.sql` is a baseline, not an executable migration.

## Clarifications & Change Tracking

- For any discrepancy with documentation or any doubt, ask the user before acting. Do not make assumptions; consult unresolved decisions in context section 15.2.
- Record significant code changes in root-level `CAMBIOS-ACTUALES.md`, including date, affected files, purpose, and validation performed. Update it alongside each significant code change.
