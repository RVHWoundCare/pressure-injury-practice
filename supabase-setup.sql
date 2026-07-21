-- Pressure Injury Staging Practice leaderboard
-- Run this entire file in Supabase: SQL Editor -> New query -> Run.
-- It is safe to run on a new project or over the earlier 80-case setup.

create table if not exists public.leaderboard_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  username text not null
    check (username ~ '^[A-Za-z0-9][A-Za-z0-9 _-]{2,23}$'),
  score smallint not null,
  total smallint not null default 40,
  duration_seconds integer not null
    check (duration_seconds between 0 and 86400),
  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, session_id)
);

-- Upgrade the earlier 80-case constraints without deleting prior rows.
alter table public.leaderboard_entries
  alter column total set default 40;

alter table public.leaderboard_entries
  drop constraint if exists leaderboard_entries_score_check,
  drop constraint if exists leaderboard_entries_total_check,
  drop constraint if exists leaderboard_score_total_check;

alter table public.leaderboard_entries
  add constraint leaderboard_score_total_check
  check (total in (40, 80) and score between 0 and total);

create index if not exists leaderboard_rank_idx
  on public.leaderboard_entries
  (score desc, duration_seconds asc, completed_at asc);

create index if not exists leaderboard_rank_40_idx
  on public.leaderboard_entries
  (score desc, duration_seconds asc, completed_at asc)
  where total = 40;

create index if not exists leaderboard_user_idx
  on public.leaderboard_entries (user_id);

alter table public.leaderboard_entries enable row level security;

drop policy if exists "Authenticated users submit their own score"
  on public.leaderboard_entries;

create policy "Authenticated users submit their own score"
  on public.leaderboard_entries
  for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

-- Do not expose internal user or session IDs through the Data API.
revoke all on table public.leaderboard_entries from anon, authenticated;
grant insert on table public.leaderboard_entries to authenticated;

-- Return only the public columns needed by the top-50 leaderboard.
create or replace function public.get_leaderboard(
  max_rows integer default 50,
  target_session uuid default null
)
returns table (
  "position" bigint,
  username text,
  score smallint,
  total smallint,
  duration_seconds integer,
  completed_at timestamptz,
  is_current boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    row_number() over (
      order by e.score desc, e.duration_seconds asc, e.completed_at asc
    ) as position,
    e.username,
    e.score,
    e.total,
    e.duration_seconds,
    e.completed_at,
    e.session_id = target_session as is_current
  from public.leaderboard_entries as e
  where e.total = 40
  order by e.score desc, e.duration_seconds asc, e.completed_at asc
  limit least(greatest(max_rows, 1), 100);
$$;

revoke all on function public.get_leaderboard(integer, uuid) from public;
revoke all on function public.get_leaderboard(integer, uuid) from anon;
grant execute on function public.get_leaderboard(integer, uuid) to authenticated;

-- ============================================================================
-- Administrator access for clinical-simulation image uploads
-- ============================================================================

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- This allowlist is intentionally deny-by-default. The security-definer
-- function below is its only application-facing access path.
alter table private.admin_users enable row level security;

revoke all on table private.admin_users from public, anon, authenticated;

create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.admin_users as a
    where a.user_id = (select auth.uid())
  );
$$;

revoke all on function public.is_current_user_admin() from public;
revoke all on function public.is_current_user_admin() from anon;
grant execute on function public.is_current_user_admin() to authenticated;

create table if not exists public.case_images (
  case_id text primary key
    check (case_id ~ '^PI-0[1-8]-(0[1-9]|10)$'),
  storage_path text not null unique
    check (storage_path ~ '^cases/PI-0[1-8]-(0[1-9]|10)/image\.(jpg|jpeg|png|webp|avif)$'),
  alt_text text not null check (char_length(alt_text) between 10 and 240),
  updated_at timestamptz not null default now()
);

alter table public.case_images enable row level security;

drop policy if exists "Anyone can read active case images" on public.case_images;
drop policy if exists "Admins can insert case images" on public.case_images;
drop policy if exists "Admins can update case images" on public.case_images;
drop policy if exists "Admins can delete case images" on public.case_images;

create policy "Anyone can read active case images"
  on public.case_images
  for select
  to anon, authenticated
  using (true);

create policy "Admins can insert case images"
  on public.case_images
  for insert
  to authenticated
  with check ((select public.is_current_user_admin()));

create policy "Admins can update case images"
  on public.case_images
  for update
  to authenticated
  using ((select public.is_current_user_admin()))
  with check ((select public.is_current_user_admin()));

create policy "Admins can delete case images"
  on public.case_images
  for delete
  to authenticated
  using ((select public.is_current_user_admin()));

revoke all on table public.case_images from public, anon, authenticated;
grant select on table public.case_images to anon, authenticated;
grant insert, update, delete on table public.case_images to authenticated;

-- Public downloads are appropriate because these files must display on the
-- public quiz. Upload, replacement, listing, and deletion remain admin-only.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'case-images',
  'case-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Admins can read case image objects" on storage.objects;
drop policy if exists "Admins can upload case image objects" on storage.objects;
drop policy if exists "Admins can update case image objects" on storage.objects;
drop policy if exists "Admins can delete case image objects" on storage.objects;

create policy "Admins can read case image objects"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'case-images'
    and (select public.is_current_user_admin())
  );

create policy "Admins can upload case image objects"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'case-images'
    and name ~ '^cases/PI-0[1-8]-(0[1-9]|10)/image\.(jpg|jpeg|png|webp|avif)$'
    and (select public.is_current_user_admin())
  );

create policy "Admins can update case image objects"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'case-images'
    and (select public.is_current_user_admin())
  )
  with check (
    bucket_id = 'case-images'
    and name ~ '^cases/PI-0[1-8]-(0[1-9]|10)/image\.(jpg|jpeg|png|webp|avif)$'
    and (select public.is_current_user_admin())
  );

create policy "Admins can delete case image objects"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'case-images'
    and (select public.is_current_user_admin())
  );

comment on table public.leaderboard_entries is
  'Practice scores submitted by anonymous authenticated users; the active leaderboard uses 40-case rows.';

comment on function public.get_leaderboard(integer, uuid) is
  'Returns ranked public leaderboard fields without exposing user or session IDs.';

comment on table public.case_images is
  'Public metadata for administrator-uploaded AI-generated case image overrides.';

comment on function public.is_current_user_admin() is
  'Returns true only when the authenticated user is in the private administrator allowlist.';
