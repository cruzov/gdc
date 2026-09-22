-- ============================================================
-- GDC - Grupo Desportivo de Calvão
-- Schema COMPLETO E CONSOLIDADO (estado final, não incremental)
-- Usar para criar um projeto Supabase NOVO (ex: staging)
-- Corre isto de uma vez só, no SQL Editor de um projeto vazio.
-- ============================================================

create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- TABELAS
-- ------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'pending' check (role in ('admin', 'coach', 'parent', 'pending')),
  email text,
  created_at timestamptz not null default now()
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.team_coaches (
  team_id uuid not null references public.teams(id) on delete cascade,
  coach_id uuid not null references public.profiles(id) on delete cascade,
  primary key (team_id, coach_id)
);

create table public.athletes (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  name text not null,
  birth_year int,
  parent_id uuid references public.profiles(id) on delete set null,
  parent_email text,
  created_at timestamptz not null default now()
);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  type text not null check (type in ('Treino', 'Jogo')),
  label text not null,
  date date not null,
  created_at timestamptz not null default now()
);

create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  athlete_id uuid not null references public.athletes(id) on delete cascade,
  present boolean not null default false,
  behavior text check (behavior in ('Bom', 'Razoável', 'Mau')),
  updated_at timestamptz not null default now(),
  unique (event_id, athlete_id)
);

create table public.incidents (
  id uuid primary key default gen_random_uuid(),
  athlete_id uuid not null references public.athletes(id) on delete cascade,
  description text not null,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_by_role text not null check (created_by_role in ('coach', 'parent')),
  date date not null default current_date,
  created_at timestamptz not null default now()
);

create table public.call_ups (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null unique references public.events(id) on delete cascade,
  status text not null default 'draft' check (status in ('draft', 'sent')),
  sent_at timestamptz,
  last_notified_athlete_ids uuid[] not null default '{}',
  created_at timestamptz not null default now()
);

create table public.call_up_athletes (
  id uuid primary key default gen_random_uuid(),
  call_up_id uuid not null references public.call_ups(id) on delete cascade,
  athlete_id uuid not null references public.athletes(id) on delete cascade,
  unique (call_up_id, athlete_id)
);

-- ------------------------------------------------------------
-- FUNÇÕES AUXILIARES (security definer = não reativam RLS
-- das tabelas que consultam por dentro; evita recursão infinita)
-- ------------------------------------------------------------

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.is_coach_of_team(t_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_coaches where team_id = t_id and coach_id = auth.uid());
$$;

create or replace function public.is_parent_of_athlete(a_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.athletes where id = a_id and parent_id = auth.uid());
$$;

create or replace function public.event_team_id(p_event_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select team_id from public.events where id = p_event_id;
$$;

create or replace function public.callup_team_id(p_call_up_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select e.team_id from public.call_ups cu
  join public.events e on e.id = cu.event_id
  where cu.id = p_call_up_id;
$$;

create or replace function public.callup_status(p_call_up_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select status from public.call_ups where id = p_call_up_id;
$$;

create or replace function public.callup_has_parent_athlete(p_call_up_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.call_up_athletes cua
    join public.athletes a on a.id = cua.athlete_id
    where cua.call_up_id = p_call_up_id and a.parent_id = auth.uid()
  );
$$;

create or replace function public.callup_visible_to_parent(p_call_up_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select
    exists (
      select 1 from public.call_ups cu
      join public.events e on e.id = cu.event_id
      join public.athletes a on a.team_id = e.team_id
      where cu.id = p_call_up_id and a.parent_id = auth.uid()
    )
    or exists (
      select 1 from public.call_up_athletes cua
      join public.athletes a on a.id = cua.athlete_id
      where cua.call_up_id = p_call_up_id and a.parent_id = auth.uid()
    );
$$;

create or replace function public.event_has_my_callup(p_event_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.call_ups cu
    join public.call_up_athletes cua on cua.call_up_id = cu.id
    join public.athletes a on a.id = cua.athlete_id
    where cu.event_id = p_event_id and cu.status = 'sent' and a.parent_id = auth.uid()
  );
$$;

create or replace function public.team_has_my_callup_game(p_team_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.events e
    join public.call_ups cu on cu.event_id = e.id
    join public.call_up_athletes cua on cua.call_up_id = cu.id
    join public.athletes a on a.id = cua.athlete_id
    where e.team_id = p_team_id and cu.status = 'sent' and a.parent_id = auth.uid()
  );
$$;

create or replace function public.events_started_map(event_ids uuid[])
returns table(event_id uuid, started boolean)
language sql stable security definer set search_path = public
as $$
  select e.id as event_id, exists(select 1 from public.attendance a where a.event_id = e.id) as started
  from public.events e
  where e.id = any(event_ids);
$$;

create or replace function public.set_athlete_parent_email(p_athlete_id uuid, p_email text)
returns table(linked boolean, linked_name text)
language plpgsql security definer set search_path = public
as $$
declare
  v_team_id uuid;
  v_has_parent boolean;
  v_profile record;
  v_clean_email text;
begin
  select team_id, (parent_id is not null) into v_team_id, v_has_parent
    from public.athletes where id = p_athlete_id;

  if v_team_id is null then
    raise exception 'Atleta não encontrado';
  end if;
  if not (public.is_admin() or public.is_coach_of_team(v_team_id)) then
    raise exception 'Sem permissão';
  end if;
  if v_has_parent then
    raise exception 'Este atleta já tem um encarregado de educação associado.';
  end if;

  v_clean_email := nullif(trim(p_email), '');

  if v_clean_email is null then
    update public.athletes set parent_email = null where id = p_athlete_id;
    return query select false, null::text;
    return;
  end if;

  select * into v_profile from public.profiles
   where lower(email) = lower(v_clean_email) and role in ('pending', 'parent')
   limit 1;

  if v_profile.id is not null then
    update public.athletes set parent_id = v_profile.id, parent_email = null where id = p_athlete_id;
    if v_profile.role = 'pending' then
      update public.profiles set role = 'parent' where id = v_profile.id;
    end if;
    return query select true, v_profile.name;
  else
    update public.athletes set parent_email = v_clean_email, parent_id = null where id = p_athlete_id;
    return query select false, null::text;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- Criação automática de perfil ao registar conta + ligação
-- automática se o email já estava à espera num atleta + o
-- primeiro utilizador de sempre torna-se admin.
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger as $$
declare
  chosen_name text;
  matched_count int;
begin
  chosen_name := coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1));

  insert into public.profiles (id, name, role, email)
  values (new.id, chosen_name, 'pending', new.email)
  on conflict (id) do nothing;

  update public.athletes
     set parent_id = new.id, parent_email = null
   where parent_id is null
     and parent_email is not null
     and lower(parent_email) = lower(new.email);
  get diagnostics matched_count = row_count;

  if matched_count > 0 then
    update public.profiles set role = 'parent' where id = new.id;
  end if;

  if (select count(*) from public.profiles) = 1 then
    update public.profiles set role = 'admin' where id = new.id;
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_coaches enable row level security;
alter table public.athletes enable row level security;
alter table public.events enable row level security;
alter table public.attendance enable row level security;
alter table public.incidents enable row level security;
alter table public.call_ups enable row level security;
alter table public.call_up_athletes enable row level security;

create policy "profiles_select" on public.profiles for select using (auth.uid() is not null);
create policy "profiles_update_self" on public.profiles for update using (auth.uid() = id);
create policy "profiles_insert_self" on public.profiles for insert with check (auth.uid() = id);
create policy "profiles_admin_all" on public.profiles for all using (public.is_admin());

create policy "teams_admin_all" on public.teams for all using (public.is_admin());
create policy "teams_select_coach" on public.teams for select using (public.is_coach_of_team(id));
create policy "teams_select_parent" on public.teams for select using (
  exists (select 1 from public.athletes a where a.team_id = teams.id and a.parent_id = auth.uid())
);
create policy "teams_coach_browse" on public.teams for select using (
  exists (select 1 from public.profiles where id = auth.uid() and role = 'coach')
);
create policy "teams_parent_select_callup" on public.teams for select using (
  public.team_has_my_callup_game(teams.id)
);

create policy "team_coaches_admin_all" on public.team_coaches for all using (public.is_admin());
create policy "team_coaches_select_self" on public.team_coaches for select using (coach_id = auth.uid());

create policy "athletes_admin_all" on public.athletes for all using (public.is_admin());
create policy "athletes_coach_all" on public.athletes for all using (public.is_coach_of_team(team_id));
create policy "athletes_parent_select" on public.athletes for select using (parent_id = auth.uid());
create policy "athletes_coach_browse" on public.athletes for select using (
  exists (select 1 from public.profiles where id = auth.uid() and role = 'coach')
);

create policy "events_admin_all" on public.events for all using (public.is_admin());
create policy "events_coach_all" on public.events for all using (public.is_coach_of_team(team_id));
create policy "events_parent_select" on public.events for select using (
  exists (select 1 from public.athletes a where a.team_id = events.team_id and a.parent_id = auth.uid())
);
create policy "events_parent_select_callup" on public.events for select using (
  public.event_has_my_callup(events.id)
);

create policy "attendance_admin_all" on public.attendance for all using (public.is_admin());
create policy "attendance_coach_all" on public.attendance for all using (
  exists (select 1 from public.events e where e.id = attendance.event_id and public.is_coach_of_team(e.team_id))
);
create policy "attendance_parent_select" on public.attendance for select using (
  public.is_parent_of_athlete(athlete_id)
);

create policy "incidents_admin_all" on public.incidents for all using (public.is_admin());
create policy "incidents_coach_all" on public.incidents for all using (
  exists (select 1 from public.athletes a where a.id = incidents.athlete_id and public.is_coach_of_team(a.team_id))
);
create policy "incidents_parent_select" on public.incidents for select using (
  public.is_parent_of_athlete(athlete_id)
);
create policy "incidents_parent_insert" on public.incidents for insert with check (
  public.is_parent_of_athlete(athlete_id) and created_by = auth.uid() and created_by_role = 'parent'
);

create policy "call_ups_admin_all" on public.call_ups for all using (public.is_admin());
create policy "call_ups_coach_all" on public.call_ups for all using (
  public.is_coach_of_team(public.event_team_id(call_ups.event_id))
) with check (
  public.is_coach_of_team(public.event_team_id(call_ups.event_id))
);
create policy "call_ups_parent_select" on public.call_ups for select using (
  call_ups.status = 'sent' and public.callup_visible_to_parent(call_ups.id)
);

create policy "call_up_athletes_admin_all" on public.call_up_athletes for all using (public.is_admin());
create policy "call_up_athletes_coach_all" on public.call_up_athletes for all using (
  public.is_coach_of_team(public.callup_team_id(call_up_athletes.call_up_id))
);
create policy "call_up_athletes_parent_select" on public.call_up_athletes for select using (
  public.callup_status(call_up_athletes.call_up_id) = 'sent'
  and public.is_parent_of_athlete(call_up_athletes.athlete_id)
);

-- ============================================================
-- FIM — schema completo aplicado
-- ============================================================
