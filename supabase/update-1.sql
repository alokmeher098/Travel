-- Envelora update 1: a phone with an older copy of the clan can no longer drop members.
-- Members are combined; someone leaves only when the app marks them as removed.
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

  if p_k = 'clan' and exists_row then
    -- chat: keep every message from both copies
    if old ? 'messages' and p_v ? 'messages' then
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
    -- members: keep people this copy doesn't know about, unless they were removed on purpose
    p_v := jsonb_set(p_v, '{members}', coalesce(p_v->'members','[]'::jsonb) || coalesce((
      select jsonb_agg(m) from jsonb_array_elements(coalesce(old->'members','[]'::jsonb)) m
      where not exists (select 1 from jsonb_array_elements(coalesce(p_v->'members','[]'::jsonb)) n where n->>'accountId' = m->>'accountId')
        and not coalesce(p_v->'removed','[]'::jsonb) ? (m->>'accountId')
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
