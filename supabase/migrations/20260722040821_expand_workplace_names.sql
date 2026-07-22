-- Expand the participant-facing workplace names without changing IDs or codes.
update public.workplaces
set display_name = case id
  when 'rvh' then 'Royal Victoria Regional Health Centre'
  when 'osmh' then 'Orillia Soldiers'' Memorial Hospital'
  else display_name
end
where id in ('rvh', 'osmh');
