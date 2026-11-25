-- Envelora update 4: videos, ticket files and per-clan space limits
-- Run AFTER update-2.sql and update-3.sql. Paste into Supabase → SQL Editor → Run. Safe to run more than once.
--
-- Files live on members' phones; the server only delivers them between clan members.
-- Limits per clan: photos + videos 1 GB, tickets 150 MB; one file up to 50 MB.

update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime','application/pdf']
 where id = 'clan-photos';

-- bytes a clan already uses on the server (tickets folder or photos/videos)
create or replace function public.clan_files_used(p_clan text, p_tickets boolean)
returns bigint language sql stable security definer set search_path = '' as $$
  select coalesce(sum(coalesce((o.metadata->>'size')::bigint, 0)), 0)::bigint
  from storage.objects o
  where o.bucket_id = 'clan-photos'
    and (storage.foldername(o.name))[1] = p_clan
    and (case when p_tickets then (storage.foldername(o.name))[2] = 'tickets'
              else coalesce((storage.foldername(o.name))[2], '') <> 'tickets' end)
$$;

drop policy if exists "clan photos: members upload" on storage.objects;
create policy "clan photos: members upload" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'clan-photos'
    and public.is_clan_member((storage.foldername(name))[1])
    and (case when (storage.foldername(name))[2] = 'tickets'
              then public.clan_role((storage.foldername(name))[1]) in ('leader','co')
                   and public.clan_files_used((storage.foldername(name))[1], true) < 157286400
              else public.clan_files_used((storage.foldername(name))[1], false) < 1073741824 end)
  );

drop policy if exists "clan photos: members delete" on storage.objects;
create policy "clan photos: members delete" on storage.objects for delete to authenticated
  using (
    bucket_id = 'clan-photos'
    and public.is_clan_member((storage.foldername(name))[1])
    and (public.clan_role((storage.foldername(name))[1]) in ('leader','co')
         or (owner_id = (select auth.uid())::text and coalesce((storage.foldername(name))[2], '') <> 'tickets'))
  );

revoke execute on function public.clan_files_used(text, boolean) from public, anon;
grant execute on function public.clan_files_used(text, boolean) to authenticated;
