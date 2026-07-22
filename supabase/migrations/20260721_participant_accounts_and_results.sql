-- Participant accounts, workplace access, resumable attempts, and admin results.
-- Workplace codes are stored only as SHA-256 hashes. The plaintext codes do
-- not belong in GitHub or browser-delivered JavaScript.

create table if not exists public.workplaces (
  id text primary key check (id ~ '^[a-z0-9-]{2,24}$'),
  display_name text not null,
  code_hash text not null unique check (code_hash ~ '^[0-9a-f]{64}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.workplaces enable row level security;
revoke all on table public.workplaces from public, anon, authenticated;
grant select on table public.workplaces to service_role;

insert into public.workplaces (id, display_name, code_hash, active)
values
  ('rvh', 'RVH', 'bf3a833a8d3d04275edafc09d508101567bca40bdea2ee208820f06a0a94e17f', true),
  ('osmh', 'OSMH', '8f08a1332dc8434addad0f9104d68c75d3e6a5412af24820671f50f12c5ebad7', true)
on conflict (id) do update set
  display_name = excluded.display_name,
  code_hash = excluded.code_hash,
  active = excluded.active;

create table if not exists public.participant_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null
    check (username ~ '^[A-Za-z0-9][A-Za-z0-9 _-]{2,23}$'),
  username_key text not null unique
    check (username_key = lower(username_key)
      and username_key ~ '^[a-z0-9][a-z0-9 _-]{2,23}$'),
  workplace_id text not null references public.workplaces(id),
  created_at timestamptz not null default now()
);

create index if not exists participant_profiles_workplace_idx
  on public.participant_profiles (workplace_id);

alter table public.participant_profiles enable row level security;

drop policy if exists "Participants read their own profile"
  on public.participant_profiles;
drop policy if exists "Admins read participant profiles"
  on public.participant_profiles;

create policy "Participants read their own profile"
  on public.participant_profiles
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Admins read participant profiles"
  on public.participant_profiles
  for select
  to authenticated
  using ((select public.is_current_user_admin()));

revoke all on table public.participant_profiles from public, anon, authenticated;
grant select on table public.participant_profiles to authenticated;
grant select, insert, update, delete on table public.participant_profiles to service_role;

create table if not exists public.participant_attempts (
  attempt_id uuid primary key,
  user_id uuid not null references public.participant_profiles(user_id)
    on delete cascade,
  username text not null,
  workplace_id text not null references public.workplaces(id),
  status text not null default 'in_progress'
    check (status in ('in_progress', 'completed')),
  state jsonb not null check (jsonb_typeof(state) = 'object'),
  score smallint not null default 0 check (score between 0 and 40),
  total smallint not null default 40 check (total = 40),
  duration_seconds integer not null default 0
    check (duration_seconds between 0 and 86400),
  started_at timestamptz not null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (status = 'in_progress' and completed_at is null)
    or (status = 'completed' and completed_at is not null)
  )
);

create index if not exists participant_attempts_user_updated_idx
  on public.participant_attempts (user_id, updated_at desc);

create index if not exists participant_attempts_completed_idx
  on public.participant_attempts (completed_at desc)
  where status = 'completed';

create index if not exists participant_attempts_workplace_idx
  on public.participant_attempts (workplace_id, completed_at desc);

alter table public.participant_attempts enable row level security;

drop policy if exists "Participants read their own attempts"
  on public.participant_attempts;
drop policy if exists "Admins read participant attempts"
  on public.participant_attempts;

create policy "Participants read their own attempts"
  on public.participant_attempts
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Admins read participant attempts"
  on public.participant_attempts
  for select
  to authenticated
  using ((select public.is_current_user_admin()));

revoke all on table public.participant_attempts from public, anon, authenticated;
grant select on table public.participant_attempts to authenticated;
grant select, insert, update, delete on table public.participant_attempts to service_role;

create or replace function public.save_participant_attempt(
  p_attempt_id uuid,
  p_state jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_username text;
  v_workplace_id text;
  v_status text;
  v_score smallint;
  v_answered integer;
  v_duration integer;
  v_started_at timestamptz;
  v_completed_at timestamptz;
  v_existing_user uuid;
  v_existing_status text;
  v_active_cases constant text[] := array[
    'PI-01-01','PI-01-02','PI-01-03','PI-01-04','PI-01-05',
    'PI-02-01','PI-02-02','PI-02-03','PI-02-05','PI-02-06',
    'PI-03-01','PI-03-02','PI-03-04','PI-03-05','PI-03-06',
    'PI-04-02','PI-04-03','PI-04-04','PI-04-05','PI-04-06',
    'PI-05-01','PI-05-03','PI-05-04','PI-05-05','PI-05-06',
    'PI-06-01','PI-06-02','PI-06-04','PI-06-05','PI-06-06',
    'PI-07-01','PI-07-02','PI-07-03','PI-07-05','PI-07-06',
    'PI-08-01','PI-08-02','PI-08-03','PI-08-05','PI-08-06'
  ];
begin
  if v_user_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  select p.username, p.workplace_id
    into v_username, v_workplace_id
  from public.participant_profiles as p
  where p.user_id = v_user_id;

  if not found then
    raise exception 'A participant account is required.' using errcode = '42501';
  end if;

  if p_state is null
    or jsonb_typeof(p_state) <> 'object'
    or octet_length(p_state::text) > 250000 then
    raise exception 'Invalid attempt state.' using errcode = '22023';
  end if;

  if p_state ->> 'sessionId' is distinct from p_attempt_id::text
    or jsonb_typeof(p_state -> 'caseOrder') <> 'array'
    or jsonb_array_length(p_state -> 'caseOrder') <> 40
    or jsonb_typeof(p_state -> 'answers') <> 'object' then
    raise exception 'Attempt state is incomplete or inconsistent.' using errcode = '22023';
  end if;

  if (select count(distinct item.value)
      from jsonb_array_elements_text(p_state -> 'caseOrder') as item(value)) <> 40
    or exists (
      select 1
      from jsonb_array_elements_text(p_state -> 'caseOrder') as item(value)
      where not (item.value = any(v_active_cases))
    ) then
    raise exception 'Attempt case order does not match the active 40-case form.'
      using errcode = '22023';
  end if;

  select count(*)::integer
    into v_answered
  from jsonb_each(p_state -> 'answers');

  if v_answered > 40
    or exists (
      select 1
      from jsonb_each(p_state -> 'answers') as answer
      where not (answer.key = any(v_active_cases))
        or jsonb_typeof(answer.value) <> 'object'
        or answer.value ->> 'classification' is null
        or not (
          answer.value ->> 'classification' = any(array[
            'Stage 1 Pressure Injury',
            'Stage 2 Pressure Injury',
            'Stage 3 Pressure Injury',
            'Stage 4 Pressure Injury',
            'Unstageable Pressure Injury',
            'Deep Tissue Pressure Injury',
            'Mucosal Membrane Pressure Injury — Not Stageable'
          ])
        )
    ) then
    raise exception 'Attempt answers contain an invalid case or classification.'
      using errcode = '22023';
  end if;

  v_status := case
    when coalesce((p_state ->> 'completed')::boolean, false) then 'completed'
    else 'in_progress'
  end;

  if v_status = 'completed' and v_answered <> 40 then
    raise exception 'All 40 cases are required before completion.'
      using errcode = '22023';
  end if;

  -- Calculate the score from participant selections on the server. Do not
  -- trust the browser-provided correctness booleans.
  select count(*) filter (
      where answer.value ->> 'classification' = case substring(answer.key from 4 for 2)
        when '01' then 'Stage 1 Pressure Injury'
        when '02' then 'Stage 2 Pressure Injury'
        when '03' then 'Stage 3 Pressure Injury'
        when '04' then 'Stage 4 Pressure Injury'
        when '05' then 'Unstageable Pressure Injury'
        when '06' then 'Deep Tissue Pressure Injury'
        when '07' then case answer.key
          when 'PI-07-01' then 'Stage 1 Pressure Injury'
          when 'PI-07-02' then 'Stage 2 Pressure Injury'
          when 'PI-07-03' then 'Stage 3 Pressure Injury'
          when 'PI-07-05' then 'Deep Tissue Pressure Injury'
          when 'PI-07-06' then 'Stage 2 Pressure Injury'
        end
        when '08' then 'Mucosal Membrane Pressure Injury — Not Stageable'
      end
    )::smallint
    into v_score
  from jsonb_each(p_state -> 'answers') as answer;

  p_state := jsonb_set(p_state, '{username}', to_jsonb(v_username), true);

  v_started_at := coalesce(
    nullif(p_state ->> 'sessionStartTime', '')::timestamptz,
    now()
  );
  v_completed_at := case
    when v_status = 'completed' then coalesce(
      nullif(p_state ->> 'completionTime', '')::timestamptz,
      now()
    )
    else null
  end;
  v_duration := case
    when v_completed_at is null then 0
    else greatest(
      0,
      least(86400, round(extract(epoch from (v_completed_at - v_started_at)))::integer)
    )
  end;

  select a.user_id, a.status
    into v_existing_user, v_existing_status
  from public.participant_attempts as a
  where a.attempt_id = p_attempt_id;

  if found and v_existing_user <> v_user_id then
    raise exception 'Attempt identifier is unavailable.' using errcode = '23505';
  end if;

  if v_existing_status = 'completed' then
    return jsonb_build_object(
      'status', 'completed',
      'score', (select a.score from public.participant_attempts as a
        where a.attempt_id = p_attempt_id),
      'answered', 40
    );
  end if;

  insert into public.participant_attempts (
    attempt_id,
    user_id,
    username,
    workplace_id,
    status,
    state,
    score,
    total,
    duration_seconds,
    started_at,
    completed_at,
    updated_at
  ) values (
    p_attempt_id,
    v_user_id,
    v_username,
    v_workplace_id,
    v_status,
    p_state,
    v_score,
    40,
    v_duration,
    v_started_at,
    v_completed_at,
    now()
  )
  on conflict (attempt_id) do update set
    status = excluded.status,
    state = excluded.state,
    score = excluded.score,
    duration_seconds = excluded.duration_seconds,
    completed_at = excluded.completed_at,
    updated_at = now()
  where public.participant_attempts.user_id = v_user_id
    and public.participant_attempts.status = 'in_progress';

  if v_status = 'completed' then
    insert into public.leaderboard_entries (
      user_id,
      session_id,
      username,
      score,
      total,
      duration_seconds,
      completed_at
    ) values (
      v_user_id,
      p_attempt_id,
      v_username,
      v_score,
      40,
      v_duration,
      v_completed_at
    )
    on conflict (user_id, session_id) do nothing;
  end if;

  return jsonb_build_object(
    'status', v_status,
    'score', v_score,
    'answered', v_answered
  );
end;
$$;

revoke all on function public.save_participant_attempt(uuid, jsonb) from public;
revoke all on function public.save_participant_attempt(uuid, jsonb) from anon;
grant execute on function public.save_participant_attempt(uuid, jsonb)
  to authenticated;

-- The public leaderboard contains aliases and aggregate scores only.
revoke insert on table public.leaderboard_entries from authenticated;
grant select on table public.leaderboard_entries to service_role;
grant execute on function public.get_leaderboard(integer, uuid)
  to anon, authenticated;

comment on table public.workplaces is
  'Active workplace access-code hashes used only by the participant account Edge Function.';
comment on table public.participant_profiles is
  'Unique participant aliases and workplace membership linked to Supabase Auth users.';
comment on table public.participant_attempts is
  'Resumable full assessment state and completed case-level results.';
comment on function public.save_participant_attempt(uuid, jsonb) is
  'Validates and stores the authenticated participant attempt; completed attempts are added to the public leaderboard.';
