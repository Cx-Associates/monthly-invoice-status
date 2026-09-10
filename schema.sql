-- ============================================================================
-- Monthly Invoice Status — Supabase schema
-- ============================================================================
-- Run this once in your Supabase project's SQL Editor (Database > SQL Editor).
-- This can live in the same Supabase project you already use for other
-- tools (ykddpajaqftrcmmhizoq), or a fresh project — either works, since
-- every table name below is specific to this tool.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- people: one row per real account. id = the Supabase Auth user's UID.
-- You create the Auth account first (Authentication > Users > Invite user),
-- then insert the matching row here (see seed section at the bottom).
-- ----------------------------------------------------------------------------
create table people (
  id uuid primary key references auth.users(id) on delete cascade,
  canonical_name text not null,
  email text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- name_aliases: the free-text name strings that show up in the Ajera export
-- (Project Manager / Marketing Contact / Billing Manager columns), each
-- pointing at the person they refer to. A person can have more than one
-- alias (nicknames, a recurring typo, a maiden name, etc). This table is
-- also what the "Import errors" flagging matches against.
-- ----------------------------------------------------------------------------
create table name_aliases (
  id bigint generated always as identity primary key,
  alias text not null unique,
  person_id uuid not null references people(id) on delete cascade
);

-- ----------------------------------------------------------------------------
-- project_months: one row per project per month. This is the whole dataset —
-- both the Ajera-sourced financial columns and the PM-entered review columns
-- live on the same row, which is what makes the field-level merge possible.
-- ----------------------------------------------------------------------------
create table project_months (
  id bigint generated always as identity primary key,
  project_id text not null,
  month date not null,                 -- always stored as the 1st of the month
  description text,
  client text,

  -- Ajera-sourced, refreshed on every import. Never edited by PMs directly.
  pm_name_raw text,
  mc_name_raw text,
  bm_name_raw text,
  total_contract_amount numeric,
  billed numeric,
  spent numeric,
  spend_remaining numeric,
  bill_remaining numeric,
  wip numeric,
  active boolean not null default true, -- false if this project vanished from a later import

  -- PM/MC/BM-entered, preserved across re-imports.
  requested_bill_amount numeric,
  action text,
  notes text,
  admin_notes text,                     -- admin-only field (the old "Eric Notes" column)
  reviewed boolean not null default false,
  reviewed_by uuid references people(id),
  reviewed_at timestamptz,

  updated_at timestamptz not null default now(),
  unique (project_id, month)
);

-- ----------------------------------------------------------------------------
-- import_runs / import_errors: a log of each monthly import and any PM/MC/BM
-- names in that import that didn't match a known alias.
-- ----------------------------------------------------------------------------
create table import_runs (
  id bigint generated always as identity primary key,
  month date not null,
  imported_by uuid references people(id),
  imported_at timestamptz not null default now(),
  row_count int,
  new_project_count int,
  unresolved_name_count int
);

create table import_errors (
  id bigint generated always as identity primary key,
  import_run_id bigint references import_runs(id) on delete cascade,
  project_id text,
  role text,          -- 'Project Manager' | 'Marketing Contact' | 'Billing Manager' | 'Missing Project'
  raw_name text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- ============================================================================
-- Row Level Security
-- ============================================================================

alter table people enable row level security;
alter table name_aliases enable row level security;
alter table project_months enable row level security;
alter table import_runs enable row level security;
alter table import_errors enable row level security;

-- Everyone signed in can read the roster and aliases (needed to show names
-- and to resolve "who can edit this row" client-side); only admins can write.
create policy people_select on people
  for select using (auth.role() = 'authenticated');
create policy people_admin_write on people
  for all using (exists (select 1 from people p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from people p where p.id = auth.uid() and p.is_admin));

create policy aliases_select on name_aliases
  for select using (auth.role() = 'authenticated');
create policy aliases_admin_write on name_aliases
  for all using (exists (select 1 from people p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from people p where p.id = auth.uid() and p.is_admin));

-- Everyone can view every project (the "view all" requirement); the app UI
-- defaults PMs to their own projects, but the row-level policy itself is
-- permissive on SELECT since visibility was never meant to be restricted.
create policy pm_select on project_months
  for select using (auth.role() = 'authenticated');

-- Only admins can add/remove project rows (that happens via the Import step).
create policy pm_admin_insert on project_months
  for insert with check (exists (select 1 from people p where p.id = auth.uid() and p.is_admin));
create policy pm_admin_delete on project_months
  for delete using (exists (select 1 from people p where p.id = auth.uid() and p.is_admin));

-- Updates: allowed for admins, or for anyone whose alias matches the PM,
-- Marketing Contact, or Billing Manager named on that specific row.
-- (Which *columns* they're allowed to change is enforced separately below
-- by a trigger, since Postgres RLS itself is row-level, not column-level.)
create policy pm_update on project_months
  for update
  using (
    exists (select 1 from people p where p.id = auth.uid() and p.is_admin)
    or exists (
      select 1 from name_aliases na
      where na.person_id = auth.uid()
        and lower(na.alias) in (lower(pm_name_raw), lower(mc_name_raw), lower(bm_name_raw))
    )
  )
  with check (true);

create policy runs_admin on import_runs
  for all using (exists (select 1 from people p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from people p where p.id = auth.uid() and p.is_admin));
create policy errors_admin on import_errors
  for all using (exists (select 1 from people p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from people p where p.id = auth.uid() and p.is_admin));

-- ============================================================================
-- Column protection: a non-admin can update a row (per the policy above) but
-- must never be able to touch the Ajera-sourced fields, project identity, or
-- another admin's notes — only their own review fields. This trigger silently
-- reverts any protected column to its previous value if the person updating
-- isn't an admin, regardless of what the client sends.
-- ============================================================================
create or replace function protect_project_months_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_admin_user boolean;
begin
  select coalesce((select is_admin from people where id = auth.uid()), false) into is_admin_user;

  if not is_admin_user then
    NEW.project_id := OLD.project_id;
    NEW.month := OLD.month;
    NEW.description := OLD.description;
    NEW.client := OLD.client;
    NEW.pm_name_raw := OLD.pm_name_raw;
    NEW.mc_name_raw := OLD.mc_name_raw;
    NEW.bm_name_raw := OLD.bm_name_raw;
    NEW.total_contract_amount := OLD.total_contract_amount;
    NEW.billed := OLD.billed;
    NEW.spent := OLD.spent;
    NEW.spend_remaining := OLD.spend_remaining;
    NEW.bill_remaining := OLD.bill_remaining;
    NEW.wip := OLD.wip;
    NEW.active := OLD.active;
    NEW.admin_notes := OLD.admin_notes;
  end if;

  NEW.updated_at := now();
  return NEW;
end;
$$;

create trigger project_months_protect
  before update on project_months
  for each row execute function protect_project_months_columns();

-- ============================================================================
-- Seed: run this AFTER creating the two admin Auth accounts (Authentication >
-- Users > Invite user, for Eric and Cathleen). Copy each person's UID from
-- that screen and paste it in below.
-- ============================================================================
-- insert into people (id, canonical_name, email, is_admin) values
--   ('<eric-auth-uid>',     'Eric Hauser',            'eric@cx-associates.com',     true),
--   ('<cathleen-auth-uid>', 'Cathleen Branon-Keogh',  'cathleen@cx-associates.com', true);
--
-- Add their aliases too if the Ajera export ever spells their names
-- differently than the canonical_name above, e.g.:
-- insert into name_aliases (alias, person_id) values
--   ('Eric Hauser', '<eric-auth-uid>');
