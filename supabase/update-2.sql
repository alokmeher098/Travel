-- Envelora update 2: shared clan photos
-- 1) a private "clan-photos" storage bucket that only clan members can read, upload to and delete from
-- 2) clan_put keeps photos from every member's copy (and forgets photos that were deleted on purpose)
-- Paste all of this into Supabase → SQL Editor → Run. Safe to run more than once.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clan-photos', 'clan-photos', false, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "clan photos: members read" on storage.objects;
drop policy if exists "clan photos: members upload" on storage.objects;
drop policy if exists "clan photos: members delete" on storage.objects;

create policy "clan photos: members read" on storage.objects for select to authenticated
  using (bucket_id = 'clan-photos' and public.is_clan_member((storage.foldername(name))[1]));
create policy "clan photos: members upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'clan-photos' and public.is_clan_member((storage.foldername(name))[1]));
create policy "clan photos: members delete" on storage.objects for delete to authenticated
  using (bucket_id = 'clan-photos' and public.is_clan_member((storage.foldername(name))[1]));

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
  gone jsonb;
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
    -- photos: keep photos from both copies, minus the ones deleted on purpose (newest first)
    select coalesce(jsonb_agg(distinct g), '[]'::jsonb) into gone
      from jsonb_array_elements_text(coalesce(p_v->'photosGone','[]'::jsonb) || coalesce(old->'photosGone','[]'::jsonb)) g;
    p_v := jsonb_set(p_v, '{photosGone}', gone);
    p_v := jsonb_set(p_v, '{photos}', coalesce((
      select jsonb_agg(ph order by (ph->>'ts')::bigint desc, ph->>'id')
      from (
        select distinct on (ph->>'id') ph from (
          select ph, 1 as pri from jsonb_array_elements(coalesce(p_v->'photos','[]'::jsonb)) ph
          union all
          select ph, 2 from jsonb_array_elements(coalesce(old->'photos','[]'::jsonb)) ph
        ) x
        where not gone ? (ph->>'id')
        order by ph->>'id', pri
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
end $function$;
