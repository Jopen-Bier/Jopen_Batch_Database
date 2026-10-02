-- Alle bestanden in Supabase Storage, als één JSON-array, voor storage_sync.py.
-- Rechtstreeks uit storage.objects: volledig, zonder paginering van de API.
-- ".emptyFolderPlaceholder" zijn lege-map-markeringen van het Dashboard,
-- geen echte bestanden.
select coalesce(json_agg(json_build_object(
         'bucket', bucket_id,
         'name', name,
         'size', (metadata->>'size')::bigint,
         'etag', metadata->>'eTag',
         'updated_at', updated_at
       ) order by bucket_id, name), '[]'::json)
from storage.objects
where name not like '%.emptyFolderPlaceholder';
