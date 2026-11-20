# WedryTrack 1.0

Drying log app for weDRY Restoration. Installable web app (PWA) that works with no signal,
saves on the phone, and syncs to Supabase when a signal comes back.

## How it fits together

- `src/app.html` is the whole app. `python3 build.py` (after `npm install`) inlines jsPDF and
  supabase-js and writes the finished site to `public/`, which Vercel serves as-is.
- `public/config.js` holds the Supabase project URL and publishable key (public by design).
- `supabase/schema.sql` creates the database. Run it once in Supabase SQL Editor. Safe to re-run.

## Data and sync

- Each job is one JSON document in the `jobs` table. Every save is kept in `job_history`.
- Saves carry a version number. If two techs change the same job offline, the app merges their
  changes field by field (rooms, points and readings by id), so neither loses readings.
- Roles: the first account becomes admin. Admins can delete jobs and manage users. Techs can
  do everything else. Deactivated users lose access. Rules are enforced in the database (RLS).

## Adding a user

Admins: account chip > Manage users > Add user. Enter email, name, role and a starting password
(one is filled in). The account is ready to sign in right away. This runs through `api/add-user.js`,
a Vercel function that checks the caller is an active admin.

One-time setup: in Vercel > Settings > Environment Variables, add `SUPABASE_SECRET_KEY` with the
secret key from Supabase > Project Settings > API Keys, then redeploy. It stays on the server.

Without that setting you can still add people the old way: Supabase dashboard > Authentication >
Users > Add user (Auto Confirm), then tick Active in Manage users. New accounts that sign up on
their own start inactive so a stranger sees nothing.
