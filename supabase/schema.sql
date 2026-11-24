-- Envelora database setup. Paste all of this into Supabase → SQL Editor → New query → Run.
-- Safe: every table is locked with Row Level Security (people only see their own data / their clan's data).

create table public.user_kv (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  k text not null check (char_length(k) <= 80),
  v jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, k)
);
alter table public.user_kv enable row level security;
create policy "own rows read"   on public.user_kv for select to authenticated using (user_id = (select auth.uid()));
create policy "own rows insert" on public.user_kv for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own rows update" on public.user_kv for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows delete" on public.user_kv for delete to authenticated using (user_id = (select auth.uid()));

create table public.clan_kv (
  clan_id text not null check (clan_id ~ '^clan_[A-Za-z0-9_]+$'),
  k text not null check (k in ('clan','tickets')),
  v jsonb,
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (clan_id, k)
);
create table public.clan_members (
  clan_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (clan_id, user_id)
);
create index on public.clan_members (user_id);
alter table public.clan_kv enable row level security;
alter table public.clan_members enable row level security;

create table public.live_locs (
  clan_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name text check (char_length(name) <= 60),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  acc real,
  updated_at timestamptz not null default now(),
  primary key (clan_id, user_id)
);
alter table public.live_locs enable row level security;

create or replace function public.is_clan_member(p_clan text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.clan_members m where m.clan_id = p_clan and m.user_id = (select auth.uid()));
$$;

create policy "members read clan" on public.clan_kv for select to authenticated using (public.is_clan_member(clan_id));
create policy "see memberships" on public.clan_members for select to authenticated using (user_id = (select auth.uid()) or public.is_clan_member(clan_id));
create policy "members see locations" on public.live_locs for select to authenticated using (public.is_clan_member(clan_id));
create policy "share own location"   on public.live_locs for insert to authenticated with check (user_id = (select auth.uid()) and public.is_clan_member(clan_id));
create policy "update own location"  on public.live_locs for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()) and public.is_clan_member(clan_id));
create policy "stop sharing"         on public.live_locs for delete to authenticated using (user_id = (select auth.uid()));

-- Save a clan record (creates it, or updates it if you are a member). Chat messages are merged, never lost.
create or replace function public.clan_put(p_clan text, p_k text, p_v jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  old jsonb;
  exists_row boolean;
begin
  if uid is null then raise exception 'not logged in'; end if;
  if p_k not in ('clan','tickets') then raise exception 'bad key'; end if;
  select v into old from public.clan_kv where clan_id = p_clan and k = 'clan';
  exists_row := found;
  if exists_row then
    if not public.is_clan_member(p_clan) then raise exception 'not a member'; end if;
  else
    if p_k <> 'clan' then raise exception 'clan not found'; end if;
    if not exists (select 1 from jsonb_array_elements(coalesce(p_v->'members','[]'::jsonb)) m where m->>'accountId' = uid::text) then
      raise exception 'creator must be a member';
    end if;
  end if;

  if p_k = 'clan' and exists_row and old ? 'messages' and p_v ? 'messages' then
    p_v := jsonb_set(p_v, '{messages}', coalesce((
      select jsonb_agg(m order by (m->>'ts')::bigint, m->>'id')
      from (
        select distinct on (m->>'id') m from (
          select m, 1 as pri from jsonb_array_elements(p_v->'messages') m
          union all
          select m, 2 from jsonb_array_elements(old->'messages') m
        ) x order by m->>'id', pri
      ) y
    ), '[]'::jsonb));
  end if;

  insert into public.clan_kv (clan_id, k, v, created_by, updated_by, updated_at)
  values (p_clan, p_k, p_v, uid, uid, now())
  on conflict (clan_id, k) do update set v = excluded.v, updated_by = uid, updated_at = now();

  if p_k = 'clan' then
    delete from public.clan_members where clan_id = p_clan
      and user_id::text not in (select m->>'accountId' from jsonb_array_elements(coalesce(p_v->'members','[]'::jsonb)) m where m->>'accountId' is not null);
    insert into public.clan_members (clan_id, user_id)
      select p_clan, u.id from auth.users u
      where u.id::text in (select m->>'accountId' from jsonb_array_elements(coalesce(p_v->'members','[]'::jsonb)) m)
    on conflict do nothing;
    delete from public.live_locs l where l.clan_id = p_clan and not exists (select 1 from public.clan_members m where m.clan_id = p_clan and m.user_id = l.user_id);
  end if;
end $$;

-- Join with an invite link (checks the clan's secret token).
create or replace function public.clan_join(p_clan text, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); c jsonb;
begin
  if uid is null then raise exception 'not logged in'; end if;
  select v into c from public.clan_kv where clan_id = p_clan and k = 'clan';
  if not found then return null; end if;
  if coalesce(c->>'token','') = '' or c->>'token' <> p_token then raise exception 'invalid invite'; end if;
  insert into public.clan_members (clan_id, user_id) values (p_clan, uid) on conflict do nothing;
  return c;
end $$;

-- Delete a clan (leader only).
create or replace function public.clan_delete(p_clan text)
returns void language plpgsql security definer set search_path = '' as $$
declare c jsonb;
begin
  select v into c from public.clan_kv where clan_id = p_clan and k = 'clan';
  if not found then return; end if;
  if not exists (select 1 from jsonb_array_elements(c->'members') m where m->>'accountId' = auth.uid()::text and m->>'role' = 'leader') then
    raise exception 'only the leader can delete the clan';
  end if;
  delete from public.clan_kv where clan_id = p_clan;
  delete from public.clan_members where clan_id = p_clan;
  delete from public.live_locs where clan_id = p_clan;
end $$;

revoke all on function public.clan_put(text,text,jsonb), public.clan_join(text,text), public.clan_delete(text), public.is_clan_member(text) from public, anon;
grant execute on function public.clan_put(text,text,jsonb), public.clan_join(text,text), public.clan_delete(text), public.is_clan_member(text) to authenticated;

-- table access for the app (rows are still protected by the RLS rules above)
grant select, insert, update, delete on public.user_kv, public.live_locs to authenticated;
grant select on public.clan_kv, public.clan_members to authenticated;

alter publication supabase_realtime add table public.clan_kv, public.live_locs;
