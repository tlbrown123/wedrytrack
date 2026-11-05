-- WedryTrack 1.0 database setup.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run again: it only creates what is missing.

-- ---------- People ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  name text not null default '',
  role text not null default 'tech' check (role in ('admin','tech')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Every new login gets a profile. The very first person becomes an active admin.
-- Everyone after that starts inactive until an admin turns them on in the app (Manage users),
-- so a stranger who signs up on their own sees nothing.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first_user boolean := not exists (select 1 from public.profiles);
begin
  insert into public.profiles (id, email, name, role, active)
  values (
    new.id, new.email, split_part(new.email, '@', 1),
    case when first_user then 'admin' else 'tech' end,
    first_user
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Catch up anyone who signed up before this script ran.
insert into public.profiles (id, email, name, role, active)
select u.id, u.email, split_part(u.email, '@', 1), 'tech', false from auth.users u
on conflict (id) do nothing;
update public.profiles set role = 'admin', active = true
where not exists (select 1 from public.profiles where role = 'admin')
  and id = (select id from public.profiles order by created_at limit 1);

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active);
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role = 'admin');
$$;

alter table public.profiles enable row level security;
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select using (public.is_active() or id = auth.uid());
drop policy if exists "profiles self update" on public.profiles;
create policy "profiles self update" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists "profiles admin update" on public.profiles;
create policy "profiles admin update" on public.profiles for update using (public.is_admin()) with check (public.is_admin());

-- Techs may change their own name only. Role and active are admin-only.
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() and (new.role is distinct from old.role or new.active is distinct from old.active) then
    raise exception 'Only an admin can change roles or deactivate users';
  end if;
  if old.id = auth.uid() and old.role = 'admin' and (new.role <> 'admin' or not new.active)
     and not exists (select 1 from public.profiles where role = 'admin' and active and id <> old.id) then
    raise exception 'There must be at least one admin';
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile();

-- ---------- Jobs ----------
-- Each job is stored as one document (rooms, points, readings, atmospherics, visits)
-- so the app can work fully offline and merge changes when it reconnects.
create table if not exists public.jobs (
  id text primary key,
  doc jsonb not null,
  job_number text generated always as (doc->>'jobNumber') stored,
  customer text generated always as (doc->>'customer') stored,
  status text generated always as (doc->>'status') stored,
  deleted boolean not null default false,
  version bigint not null default 1,
  created_by uuid default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
create index if not exists jobs_updated_at on public.jobs (updated_at);

-- Every saved version of every job is kept. Drying logs are dispute evidence.
create table if not exists public.job_history (
  id bigint generated always as identity primary key,
  job_id text not null,
  version bigint not null,
  doc jsonb not null,
  deleted boolean not null,
  saved_by uuid,
  saved_at timestamptz not null default now()
);
create index if not exists job_history_job on public.job_history (job_id, version);

create or replace function public.jobs_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.version := 1;
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.version := old.version + 1;
    if new.deleted and not old.deleted and not public.is_admin() then
      raise exception 'Only an admin can delete a job';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists jobs_stamp on public.jobs;
create trigger jobs_stamp before insert or update on public.jobs
  for each row execute function public.jobs_stamp();

create or replace function public.jobs_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.job_history (job_id, version, doc, deleted, saved_by)
  values (new.id, new.version, new.doc, new.deleted, new.updated_by);
  return null;
end $$;
drop trigger if exists jobs_log on public.jobs;
create trigger jobs_log after insert or update on public.jobs
  for each row execute function public.jobs_log();

alter table public.jobs enable row level security;
drop policy if exists "jobs read" on public.jobs;
create policy "jobs read" on public.jobs for select using (public.is_active());
drop policy if exists "jobs insert" on public.jobs;
create policy "jobs insert" on public.jobs for insert with check (public.is_active());
drop policy if exists "jobs update" on public.jobs;
create policy "jobs update" on public.jobs for update using (public.is_active()) with check (public.is_active());
-- No delete policy: jobs are never hard-deleted from the app.

alter table public.job_history enable row level security;
drop policy if exists "history admin read" on public.job_history;
create policy "history admin read" on public.job_history for select using (public.is_admin());

-- Save with a version check so two techs never silently overwrite each other.
-- Returns the new version, or null if someone else saved first (the app then merges and retries).
create or replace function public.save_job(p_id text, p_doc jsonb, p_deleted boolean, p_base bigint)
returns bigint language plpgsql security invoker set search_path = public as $$
declare v bigint;
begin
  if p_base = 0 then
    insert into public.jobs (id, doc, deleted) values (p_id, p_doc, p_deleted)
    on conflict (id) do nothing returning version into v;
  else
    update public.jobs set doc = p_doc, deleted = p_deleted
    where id = p_id and version = p_base returning version into v;
  end if;
  return v;
end $$;
grant execute on function public.save_job(text, jsonb, boolean, bigint) to authenticated;
