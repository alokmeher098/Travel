-- Envelora update 3: security hardening + DPDP (delete my account)
-- Paste all of this into Supabase → SQL Editor → Run. Safe to run more than once.
--
-- What it fixes:
--  * The server now enforces clan roles itself (a modified app can't make itself leader,
--    edit the trip plan, rewrite other people's messages, or post as someone else).
--  * Only the leader / co-leaders can change tickets.
--  * Size limits so nobody can flood a clan with huge data.
--  * Functions can't be called by people who aren't logged in.
--  * delete_my_account(): DPDP right to erasure.

-- my role in a clan ('leader' | 'co' | 'member' | null)
create or replace function public.clan_role(p_clan text)
returns text language sql stable security definer set search_path = '' as $$
  select m->>'role' from public.clan_kv k, jsonb_array_elements(coalesce(k.v->'members','[]'::jsonb)) m
  where k.clan_id = p_clan and k.k = 'clan' and m->>'accountId' = (select auth.uid())::text
  limit 1
$$;

create or replace function public.clan_put(p_clan text, p_k text, p_v jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid := auth.uid();
  old jsonb;
  exists_row boolean;
  r text;
  myname text;
  gone jsonb;
  res jsonb;
  t jsonb;
  fk text;
begin
  if uid is null then raise exception 'not logged in'; end if;
  if p_k not in ('clan','tickets') then raise exception 'bad key'; end if;
  if jsonb_typeof(p_v) <> 'object' and not (p_k = 'tickets' and jsonb_typeof(p_v) = 'array') then raise exception 'bad data'; end if;
  if octet_length(p_v::text) > (case when p_k = 'tickets' then 4500000 else 1500000 end) then raise exception 'too large'; end if;

  select v into old from public.clan_kv where clan_id = p_clan and k = 'clan';
  exists_row := found;
  if exists_row then
    if not public.is_clan_member(p_clan) then raise exception 'not a member'; end if;
    select m->>'role', m->>'name' into r, myname from jsonb_array_elements(coalesce(old->'members','[]'::jsonb)) m where m->>'accountId' = uid::text limit 1;
    r := coalesce(r, 'member');   -- just joined through clan_join
  else
    if p_k <> 'clan' then raise exception 'clan not found'; end if;
    if not exists (select 1 from jsonb_array_elements(coalesce(p_v->'members','[]'::jsonb)) m where m->>'accountId' = uid::text and m->>'role' = 'leader') then
      raise exception 'creator must be the leader';
    end if;
    r := 'leader';
  end if;

  if p_k = 'tickets' and r not in ('leader','co') then raise exception 'only the leader or a co-leader can change tickets'; end if;

  if p_k = 'clan' and exists_row then
    if jsonb_typeof(coalesce(p_v->'messages','[]'::jsonb)) <> 'array' or jsonb_typeof(coalesce(p_v->'members','[]'::jsonb)) <> 'array'
       or jsonb_typeof(coalesce(p_v->'photos','[]'::jsonb)) <> 'array' then raise exception 'bad data'; end if;

    -- 1) co-leaders and members may only change what their role allows; everything else stays as it was
    if r <> 'leader' then
      res := old;
      t := old->'trip';
      if jsonb_typeof(t) = 'object' and jsonb_typeof(p_v->'trip') = 'object' then
        foreach fk in array array['expenses','packing','travellers'] loop
          if jsonb_typeof(p_v->'trip'->fk) = 'array' then t := jsonb_set(t, array[fk], p_v->'trip'->fk); end if;
        end loop;
        res := jsonb_set(res, '{trip}', t);
      end if;
      foreach fk in array (case when r = 'co'
          then array['endWarned','lastWarned','updatedAt','removed','name','desc','photo','capacity','paidTravellers','paidDays','payments','token']
          else array['endWarned','lastWarned','updatedAt','removed'] end) loop
        if p_v ? fk then res := jsonb_set(res, array[fk], p_v->fk); end if;
      end loop;
      -- members: nobody but the leader changes roles; co-leaders may remove plain members; anyone may leave or join as a member
      res := jsonb_set(res, '{members}', coalesce((
        select jsonb_agg(m) from jsonb_array_elements(coalesce(old->'members','[]'::jsonb)) m
        where not (coalesce(p_v->'removed','[]'::jsonb) ? (m->>'accountId')
                   and not exists (select 1 from jsonb_array_elements(p_v->'members') n where n->>'accountId' = m->>'accountId')
                   and (m->>'accountId' = uid::text or (r = 'co' and m->>'role' = 'member')))
      ), '[]'::jsonb) || coalesce((
        select jsonb_agg(n || jsonb_build_object('accountId', uid::text, 'role', 'member'))
        from jsonb_array_elements(p_v->'members') n
        where n->>'accountId' = uid::text
          and not exists (select 1 from jsonb_array_elements(coalesce(old->'members','[]'::jsonb)) m where m->>'accountId' = uid::text)
      ), '[]'::jsonb));
      res := jsonb_set(res, '{messages}', coalesce(p_v->'messages','[]'::jsonb));
      res := jsonb_set(res, '{photos}', coalesce(p_v->'photos','[]'::jsonb));
      res := jsonb_set(res, '{photosGone}', coalesce(p_v->'photosGone','[]'::jsonb));
      p_v := res;
    else
      -- leader: keep people this copy doesn't know about, unless they were removed on purpose
      p_v := jsonb_set(p_v, '{members}', coalesce(p_v->'members','[]'::jsonb) || coalesce((
        select jsonb_agg(m) from jsonb_array_elements(coalesce(old->'members','[]'::jsonb)) m
        where not exists (select 1 from jsonb_array_elements(coalesce(p_v->'members','[]'::jsonb)) n where n->>'accountId' = m->>'accountId')
          and not coalesce(p_v->'removed','[]'::jsonb) ? (m->>'accountId')
      ), '[]'::jsonb));
    end if;

    -- 2) chat: messages already on the server never change; new ones are posted as the caller
    p_v := jsonb_set(p_v, '{messages}', coalesce((
      select jsonb_agg(m order by (m->>'ts')::bigint, m->>'id')
      from (
        select distinct on (m->>'id') m from (
          select m, 1 as pri from jsonb_array_elements(coalesce(old->'messages','[]'::jsonb)) m
          union all
          select case when coalesce(m->>'type','') = 'system' or m->>'by' = uid::text then m
                      else m || jsonb_build_object('by', uid::text, 'name', coalesce(myname, m->>'name')) end, 2
          from jsonb_array_elements(coalesce(p_v->'messages','[]'::jsonb)) m
          where jsonb_typeof(m) = 'object' and m ? 'id'
        ) x order by m->>'id', pri
      ) y
    ), '[]'::jsonb));

    -- 3) photos: kept from both copies; new ones belong to the caller; a photo can be removed
    --    by the person who shared it or by the leader / co-leaders
    select coalesce(jsonb_agg(distinct g), '[]'::jsonb) into gone from (
      select g from jsonb_array_elements_text(coalesce(old->'photosGone','[]'::jsonb)) g
      union
      select g from jsonb_array_elements_text(case when jsonb_typeof(p_v->'photosGone') = 'array' then p_v->'photosGone' else '[]'::jsonb end) g
      where r in ('leader','co')
         or not exists (select 1 from jsonb_array_elements(coalesce(old->'photos','[]'::jsonb)) ph where ph->>'id' = g)
         or exists (select 1 from jsonb_array_elements(coalesce(old->'photos','[]'::jsonb)) ph where ph->>'id' = g and ph->>'by' = uid::text)
    ) z;
    p_v := jsonb_set(p_v, '{photosGone}', gone);
    p_v := jsonb_set(p_v, '{photos}', coalesce((
      select jsonb_agg(ph order by (ph->>'ts')::bigint desc, ph->>'id')
      from (
        select distinct on (ph->>'id') ph from (
          select ph, 1 as pri from jsonb_array_elements(coalesce(old->'photos','[]'::jsonb)) ph
          union all
          select ph || jsonb_build_object('by', uid::text), 2 from jsonb_array_elements(coalesce(p_v->'photos','[]'::jsonb)) ph
          where jsonb_typeof(ph) = 'object' and ph ? 'id'
        ) x
        where not gone ? (ph->>'id')
        order by ph->>'id', pri
      ) y
    ), '[]'::jsonb));
    if jsonb_array_length(p_v->'photos') > 2000 then raise exception 'album full'; end if;
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
        and (not exists_row or u.id = uid or exists (select 1 from public.clan_members cm where cm.clan_id = p_clan and cm.user_id = u.id))
    on conflict do nothing;
    delete from public.live_locs l where l.clan_id = p_clan and not exists (select 1 from public.clan_members m where m.clan_id = p_clan and m.user_id = l.user_id);
  end if;
end $function$;

-- DPDP: erase my account and my data
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  c record;
  nxt jsonb;
  cv jsonb;
begin
  if uid is null then raise exception 'not logged in'; end if;
  for c in select k.clan_id, k.v from public.clan_kv k where k.k = 'clan'
           and exists (select 1 from jsonb_array_elements(coalesce(k.v->'members','[]'::jsonb)) m where m->>'accountId' = uid::text) loop
    cv := c.v;
    if (select count(*) from jsonb_array_elements(cv->'members')) <= 1 then
      delete from public.clan_kv where clan_id = c.clan_id;
      delete from public.clan_members where clan_id = c.clan_id;
      delete from public.live_locs where clan_id = c.clan_id;
      continue;
    end if;
    -- leaving a clan: hand the leader role to a co-leader (or the earliest member)
    if exists (select 1 from jsonb_array_elements(cv->'members') m where m->>'accountId' = uid::text and m->>'role' = 'leader') then
      select m into nxt from jsonb_array_elements(cv->'members') m where m->>'accountId' <> uid::text
        order by (m->>'role' = 'co') desc, (m->>'joinedAt') limit 1;
      cv := jsonb_set(cv, '{members}', (select jsonb_agg(case when m->>'accountId' = nxt->>'accountId' then m || '{"role":"leader"}'::jsonb else m end)
                                     from jsonb_array_elements(cv->'members') m));
    end if;
    cv := jsonb_set(cv, '{members}', coalesce((select jsonb_agg(m) from jsonb_array_elements(cv->'members') m where m->>'accountId' <> uid::text), '[]'::jsonb));
    cv := jsonb_set(cv, '{removed}', coalesce(cv->'removed','[]'::jsonb) || to_jsonb(uid::text));
    -- remove my contact details and my name from messages
    cv := jsonb_set(cv, '{messages}', coalesce((select jsonb_agg(case when m->>'by' = uid::text then m || '{"name":"Deleted user"}'::jsonb else m end)
                                             from jsonb_array_elements(coalesce(cv->'messages','[]'::jsonb)) m), '[]'::jsonb));
    update public.clan_kv set v = cv, updated_at = now() where clan_id = c.clan_id and k = 'clan';
    delete from public.clan_members where clan_id = c.clan_id and user_id = uid;
  end loop;
  delete from public.live_locs where user_id = uid;
  delete from public.user_kv where user_id = uid;
  delete from auth.users where id = uid;
end $$;

-- nobody who isn't logged in can call these; logged-in users only what they need
revoke execute on function public.clan_put(text,text,jsonb), public.clan_join(text,text), public.clan_delete(text),
  public.is_clan_member(text), public.clan_role(text), public.delete_my_account() from public, anon;
grant execute on function public.clan_put(text,text,jsonb), public.clan_join(text,text), public.clan_delete(text),
  public.is_clan_member(text), public.clan_role(text), public.delete_my_account() to authenticated;
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'rls_auto_enable') then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end $$;
