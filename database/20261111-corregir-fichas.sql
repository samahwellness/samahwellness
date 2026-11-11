begin;
do $fix$
declare
 source text;
 old_block text;
 new_block text;
 first_marker text := 'elsif p_action=''credit'' then';
 last_marker text := 'elsif p_action in (''correct'',''undo'') then';
 first_position integer;
 last_position integer;
 staff_id uuid;
 person record;
 profile jsonb;
begin
 select pg_get_functiondef('public.samah_desk(text,jsonb)'::regprocedure) into source;
 if position(' a public.samah_reward_awards%rowtype;' in source)>0 then
   first_position := position(first_marker in source);
   last_position := position(last_marker in substring(source from first_position)) + first_position - 1;
   if first_position=0 or last_position<=first_position then
     raise exception 'La función cambió. Revisa la versión antes de aplicar la corrección.';
   end if;
   old_block := substring(source from first_position for last_position-first_position);
   new_block := replace(replace(old_block,'into a from','into selected_award from'),'a.','selected_award.');
   source := substring(source from 1 for first_position-1) || new_block || substring(source from last_position);
   source := replace(source,' a public.samah_reward_awards%rowtype;',' selected_award public.samah_reward_awards%rowtype;');
   execute source;
 elsif position(' selected_award public.samah_reward_awards%rowtype;' in source)=0 then
   raise exception 'La función cambió. Revisa la versión antes de aplicar la corrección.';
 end if;

 -- Exercise the real profile entry point, including profiles with attendance and awards.
 select user_id into strict staff_id from public.samah_staff limit 1;
 perform set_config('request.jwt.claim.sub',staff_id::text,true);
 for person in select id from public.samah_reward_students loop
   profile := public.samah_desk('profile',jsonb_build_object('student',person.id));
   if jsonb_typeof(profile->'visits')<>'array' or jsonb_typeof(profile->'awards')<>'array'
      or jsonb_typeof(profile->'packages')<>'array' or jsonb_typeof(profile->'credit_uses')<>'array' then
     raise exception 'La ficha no devolvió su historial completo';
   end if;
   if jsonb_array_length(profile->'visits')<>(select count(*) from public.samah_reward_visits where student=person.id) then
     raise exception 'El historial de asistencias no coincide';
   end if;
 end loop;
end $fix$;
commit;
select 'Fichas corregidas y apertura de todas las fichas verificada' as resultado,
       count(*) as fichas_verificadas from public.samah_reward_students;

