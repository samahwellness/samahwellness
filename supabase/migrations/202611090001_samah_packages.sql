begin;

create table public.samah_package_orders (
  id uuid primary key default gen_random_uuid(),
  student_name text not null check (length(trim(student_name)) between 1 and 80),
  student_email text not null check (length(student_email) between 3 and 120 and student_email = lower(trim(student_email))),
  class_limit integer check (class_limit in (4,9)),
  amount_mxn integer not null,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  provider_payment_id text unique,
  revoked_at timestamptz,
  check ((approved_at is null) = (provider_payment_id is null)),
  check ((class_limit = 4 and amount_mxn = 580) or (class_limit = 9 and amount_mxn = 1250)
    or (class_limit is null and amount_mxn = 1800))
);

create table public.samah_package_attendance (
  booking_id uuid primary key references public.samah_bookings(id),
  order_id uuid not null references public.samah_package_orders(id),
  recorded_by uuid not null,
  recorded_at timestamptz not null default now()
);
create index samah_attendance_order_idx on public.samah_package_attendance(order_id);
alter table public.samah_package_orders enable row level security;
alter table public.samah_package_attendance enable row level security;
revoke all on public.samah_package_orders,public.samah_package_attendance from public,anon,authenticated;

create function public.samah_mark_attendance(p_order uuid,p_booking uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare
  o public.samah_package_orders%rowtype;
  b public.samah_bookings%rowtype;
  previous_order uuid;
  used integer;
  class_start timestamptz;
begin
  if not public.samah_is_staff() then raise insufficient_privilege; end if;
  select * into strict o from public.samah_package_orders where id=p_order for update;
  select * into strict b from public.samah_bookings where id=p_booking for update;
  select order_id into previous_order from public.samah_package_attendance where booking_id=p_booking;
  select count(*) into used from public.samah_package_attendance where order_id=p_order;
  if previous_order=p_order then return o.class_limit-used; end if;
  if previous_order is not null then raise exception 'La asistencia ya está registrada con otro paquete'; end if;
  class_start := (b.class_date+b.starts) at time zone 'America/Mexico_City';
  if b.cancelled or b.access<>'Paquete Samah' or lower(trim(b.contact))<>o.student_email or class_start>now() then
    raise exception 'La reserva no coincide con el paquete o la clase aún no empieza';
  end if;
  if o.approved_at is null or o.revoked_at is not null or class_start<o.approved_at or class_start>=o.approved_at+interval '30 days' then
    raise exception 'El paquete no estaba vigente para esa clase';
  end if;
  if o.class_limit is not null and used>=o.class_limit then raise exception 'El paquete ya no tiene saldo'; end if;
  insert into public.samah_package_attendance(booking_id,order_id,recorded_by) values(p_booking,p_order,auth.uid());
  return o.class_limit-used-1;
end $$;
revoke execute on function public.samah_mark_attendance(uuid,uuid) from public,anon,authenticated;
grant execute on function public.samah_mark_attendance(uuid,uuid) to authenticated;
commit;
