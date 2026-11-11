begin;
create table public.samah_purchase_requests (
 id uuid primary key,
 first_name text not null check(length(btrim(first_name)) between 1 and 80),
 last_name text not null check(length(btrim(last_name)) between 1 and 80),
 plan text not null check(plan in ('Paquete 4','Paquete 9','Ilimitado','Clase suelta')),
 created_at timestamptz not null default now(),
 fulfilled_by uuid
);
alter table public.samah_purchase_requests enable row level security;
revoke all on public.samah_purchase_requests from anon,authenticated;
create function public.samah_checkout(p_id uuid,p_first text,p_last text,p_plan text)
returns uuid language plpgsql security definer set search_path='' as $$
begin
 if p_id is null then raise exception 'Falta la solicitud'; end if;
 insert into public.samah_purchase_requests(id,first_name,last_name,plan)
 values(p_id,btrim(p_first),btrim(p_last),p_plan) on conflict do nothing;
 return p_id;
end $$;
revoke execute on function public.samah_checkout(uuid,text,text,text) from public;
grant execute on function public.samah_checkout(uuid,text,text,text) to anon,authenticated;
create table public.samah_packages (
 id uuid primary key default gen_random_uuid(),
 student uuid not null references public.samah_reward_students(id),
 plan text not null check(plan in ('Paquete 4','Paquete 9','Ilimitado')),
 paid_at timestamptz not null,
 expires_at timestamptz,
 created_by uuid not null
);
create table public.samah_payments (
 id uuid primary key default gen_random_uuid(),
 student uuid not null references public.samah_reward_students(id),
 package_id uuid unique references public.samah_packages(id),
 visit_id uuid unique,
 day date not null,
 concept text not null,
 amount numeric(12,2) not null check(amount>=0 and amount<'Infinity'::numeric),
 method text not null check(method in ('Efectivo','Tarjeta','Transferencia','Mercado Pago','Sin cobro')),
 reference text,
 created_by uuid not null,
 check((amount=0 and method='Sin cobro') or (amount>0 and method<>'Sin cobro'))
);
create unique index samah_payment_reference on public.samah_payments(reference) where reference is not null;
alter table public.samah_reward_visits add column id uuid not null default gen_random_uuid() unique;
alter table public.samah_reward_visits add column booking_id uuid unique references public.samah_bookings(id);
alter table public.samah_reward_visits add column package_id uuid references public.samah_packages(id);
alter table public.samah_reward_visits add column note text;
alter table public.samah_reward_visits add column app_rate numeric(12,2);
alter table public.samah_reward_visits add column request_id uuid unique;
alter table public.samah_reward_visits drop constraint samah_reward_visits_channel_check;
alter table public.samah_reward_visits add constraint samah_reward_visits_channel_check check(channel in
 ('Fitpass','TotalPass','Clase suelta','Primera vez','Paquete 4','Paquete 9','Ilimitado','Paquete Samah','wellhub','Cortesia','Sin clasificar'));
alter table public.samah_bookings drop constraint samah_bookings_access_check;
alter table public.samah_bookings add constraint samah_bookings_access_check check(access in
 ('Paquete Samah','Paquete 4','Paquete 9','Ilimitado','Clase suelta','Primera vez','Fitpass','Totalpass','Wellhub'));
create table public.samah_credit_uses (
 id uuid primary key default gen_random_uuid(),
 student uuid not null,
 month date not null,
 reward text not null,
 amount numeric(12,2) not null check(amount>0 and amount<'Infinity'::numeric),
 used_at timestamptz not null default now(),
 created_by uuid not null,
 request_id uuid not null unique,
 foreign key(student,month,reward) references public.samah_reward_awards(student,month,reward)
);
create table public.samah_desk_audit (
 id bigint generated always as identity primary key,
 happened_at timestamptz not null default now(),
 actor uuid not null,
 action text not null,
 before_data jsonb,
 after_data jsonb
);
alter table public.samah_packages enable row level security;
alter table public.samah_payments enable row level security;
alter table public.samah_credit_uses enable row level security;
alter table public.samah_desk_audit enable row level security;
revoke all on public.samah_packages,public.samah_payments,public.samah_credit_uses,public.samah_desk_audit from anon,authenticated;

create function public.samah_recompute_rewards(p_student uuid,p_month date)
returns void language plpgsql security definer set search_path='' as $$
declare rule record; total bigint; earned text[] := '{}';
begin
 if not public.samah_is_staff() then raise insufficient_privilege; end if;
 perform 1 from public.samah_reward_students where id=p_student for update;
 for rule in select * from (values
 ('Fitpass',4,'Fitpass · Clase de regalo'),('TotalPass',7,'TotalPass · Pase amigo'),
 ('TotalPass',14,'TotalPass · Crédito de $200'),('Clase suelta',5,'Clase suelta · Americano mediano'),
 ('Clase suelta',8,'Clase suelta · Pase amigo'),('Clase suelta',10,'Clase suelta · Crédito de $150')
 ) r(channel,threshold,reward) loop
   select count(*) into total from public.samah_reward_visits where student=p_student and channel=rule.channel
    and day>=p_month and day<p_month+interval '1 month';
   if total>=rule.threshold then
     earned:=array_append(earned,rule.reward);
     insert into public.samah_reward_awards(student,month,reward) values(p_student,p_month,rule.reward) on conflict do nothing;
   end if;
 end loop;
 if exists(select 1 from public.samah_reward_awards a where a.student=p_student and a.month=p_month and not(a.reward=any(earned))
   and (a.redeemed_at is not null or exists(select 1 from public.samah_credit_uses c where c.student=a.student and c.month=a.month and c.reward=a.reward))) then
   raise exception 'La corrección afecta un premio usado total o parcialmente. Revisa el canje antes de corregir.';
 end if;
 delete from public.samah_reward_awards where student=p_student and month=p_month and not(reward=any(earned));
end $$;

create function public.samah_desk(p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 sid uuid := (p_data->>'student')::uuid;
 bid uuid := (p_data->>'booking_id')::uuid;
 vid uuid := (p_data->>'visit_id')::uuid;
 pid uuid := (p_data->>'package_id')::uuid;
 rid uuid := (p_data->>'request_id')::uuid;
 d date := (p_data->>'day')::date;
 t time := (p_data->>'starts')::time;
 ch text := p_data->>'channel';
 amt numeric := (p_data->>'amount')::numeric;
 extra numeric := coalesce((p_data->>'extra')::numeric,0);
 method text := p_data->>'method';
 m date;
 a public.samah_reward_awards%rowtype;
 old public.samah_reward_visits%rowtype;
 pkg public.samah_packages%rowtype;
 booking public.samah_bookings%rowtype;
 result jsonb;
 used bigint;
 cap numeric;
 spent numeric;
 ref text := nullif(btrim(p_data->>'reference'),'');
begin
 if not public.samah_is_staff() then raise insufficient_privilege; end if;
 if p_action='requests' then
   return coalesce((select jsonb_agg(to_jsonb(r) order by created_at desc) from public.samah_purchase_requests r where fulfilled_by is null),'[]');
 end if;
 if p_action='day' then
   if d is null then raise exception 'Selecciona una fecha'; end if;
   select jsonb_build_object('visits',coalesce((select jsonb_agg(to_jsonb(v)||jsonb_build_object('person',s.first_name||' '||s.last_name) order by v.starts,s.first_name)
      from public.samah_reward_visits v join public.samah_reward_students s on s.id=v.student where v.day=d),'[]'),
    'payments',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('person',s.first_name||' '||s.last_name) order by p.id)
      from public.samah_payments p join public.samah_reward_students s on s.id=p.student where p.day=d),'[]'),
    'cash',coalesce((select sum(amount) from public.samah_payments where day=d),0),
    'apps',coalesce((select sum(coalesce(app_rate,case channel when 'TotalPass' then round(120/1.16,2) when 'Fitpass' then round(80/1.16,2) end))
      from public.samah_reward_visits where day=d),0),
    'wellhub', (select count(*) from public.samah_reward_visits where day=d and channel='wellhub')) into result;
   return result;
 end if;
 if p_action in ('correct','undo') then
   select student into sid from public.samah_reward_visits where id=vid;
 end if;
 perform 1 from public.samah_reward_students where id=sid for update;
 if not found then raise exception 'Selecciona la ficha de la alumna'; end if;
 if p_action='profile' then
   return jsonb_build_object('visits',coalesce((select jsonb_agg(to_jsonb(v) order by day desc,starts desc) from public.samah_reward_visits v where student=sid),'[]'),
    'packages',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('used',(select count(*) from public.samah_reward_visits v where v.package_id=p.id)) order by paid_at desc) from public.samah_packages p where student=sid),'[]'),
    'awards',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('spent',case when a.redeemed_at is not null then case when a.reward like '%$200%' then 200 when a.reward like '%$150%' then 150 else 0 end
       else coalesce((select sum(c.amount) from public.samah_credit_uses c where c.student=a.student and c.month=a.month and c.reward=a.reward),0) end) order by a.month desc,a.reward)
       from public.samah_reward_awards a where student=sid),'[]'),
    'credit_uses',coalesce((select jsonb_agg(to_jsonb(c) order by used_at desc) from public.samah_credit_uses c where student=sid),'[]'));
 elsif p_action='sell' then
   if rid is null or d is null or d>(clock_timestamp() at time zone 'America/Mexico_City')::date then raise exception 'Revisa la fecha de cobro'; end if;
   if exists(select 1 from public.samah_packages where id=rid) then return jsonb_build_object('ok',true); end if;
   amt:=case ch when 'Paquete 4' then 580 when 'Paquete 9' then 1250 when 'Ilimitado' then 1800 end;
   if amt is null then raise exception 'Selecciona un paquete'; end if;
   if method='Mercado Pago' and ref is null then raise exception 'Indica la referencia del pago verificado'; end if;
   insert into public.samah_packages(id,student,plan,paid_at,expires_at,created_by)
    values(rid,sid,ch,d::timestamp at time zone 'America/Mexico_City',case when ch='Ilimitado' then (d::timestamp+interval '1 month') at time zone 'America/Mexico_City' end,auth.uid());
   insert into public.samah_payments(student,package_id,day,concept,amount,method,reference,created_by)
    values(sid,rid,d,ch,amt,method,ref,auth.uid());
   if p_data->>'purchase_id' is not null then
     update public.samah_purchase_requests set fulfilled_by=rid where id=(p_data->>'purchase_id')::uuid and plan=ch and fulfilled_by is null;
     if not found then raise exception 'La solicitud ya se atendió o el paquete no coincide'; end if;
   end if;
   insert into public.samah_desk_audit(actor,action,after_data) values(auth.uid(),'sell',p_data);
   return jsonb_build_object('ok',true);
 elsif p_action='credit' then
   m:=(p_data->>'month')::date;
   select * into a from public.samah_reward_awards where student=sid and month=m and reward=p_data->>'reward' for update;
   if not found then raise exception 'Premio no encontrado'; end if;
   cap:=case when a.reward like '%$200%' then 200 when a.reward like '%$150%' then 150 end;
   if cap is null then raise exception 'Selecciona un crédito de Samah'; end if;
   if rid is null then raise exception 'Falta el identificador de canje'; end if;
   if exists(select 1 from public.samah_credit_uses where request_id=rid) then return jsonb_build_object('ok',true); end if;
   select coalesce(sum(amount),0) into spent from public.samah_credit_uses where student=sid and month=m and reward=a.reward;
   if a.redeemed_at is not null or amt is null or amt<=0 or amt>cap-spent then raise exception 'El importe supera el saldo disponible'; end if;
   insert into public.samah_credit_uses(student,month,reward,amount,created_by,request_id) values(sid,m,a.reward,amt,auth.uid(),rid);
   if spent+amt=cap then update public.samah_reward_awards set redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where student=sid and month=m and reward=a.reward; end if;
   return jsonb_build_object('ok',true);
 elsif p_action in ('correct','undo') then
   select * into old from public.samah_reward_visits where id=vid for update;
   if not found then raise exception 'Asistencia no encontrada'; end if;
   d:=old.day; t:=old.starts; bid:=old.booking_id;
   if p_action='undo' then
     delete from public.samah_payments where visit_id=vid;
     delete from public.samah_reward_visits where id=vid;
     perform public.samah_recompute_rewards(sid,date_trunc('month',d::timestamp)::date);
     insert into public.samah_desk_audit(actor,action,before_data) values(auth.uid(),'undo',to_jsonb(old));
     return jsonb_build_object('ok',true);
   end if;
 elsif p_action='attend' then
   if rid is null then raise exception 'Falta el identificador de asistencia'; end if;
   select * into old from public.samah_reward_visits where request_id=rid;
   if found then return jsonb_build_object('ok',true); end if;
   if bid is not null then
     select * into booking from public.samah_bookings where id=bid and not cancelled for update;
     if not found then raise exception 'La reserva ya no está activa'; end if;
     d:=booking.class_date; t:=booking.starts;
   end if;
   if exists(select 1 from public.samah_reward_visits where student=sid and day=d and starts=t) then
     raise exception 'Ya existe una asistencia para esta ficha, fecha y hora. Corrígela desde el historial.';
   end if;
 else raise exception 'Acción desconocida';
 end if;
 if d is null or t is null or (d+t)>(clock_timestamp() at time zone 'America/Mexico_City') then raise exception 'La clase debe haber ocurrido'; end if;
 if ch not in ('Fitpass','TotalPass','wellhub','Clase suelta','Primera vez','Paquete 4','Paquete 9','Ilimitado','Cortesia') or ch is null then raise exception 'Revisa el acceso'; end if;
 if extra<0 or extra>1000000 then raise exception 'Revisa el extra de actividad'; end if;
 if ch in ('Paquete 4','Paquete 9','Ilimitado') then
   select * into pkg from public.samah_packages where id=pid and student=sid and plan=ch for update;
   if not found then raise exception 'Selecciona un paquete pagado de esta ficha'; end if;
   if ((d+t) at time zone 'America/Mexico_City')<pkg.paid_at or (pkg.expires_at is not null and ((d+t) at time zone 'America/Mexico_City')>=pkg.expires_at) then raise exception 'La fecha de la clase está fuera de la vigencia'; end if;
   select count(*) into used from public.samah_reward_visits where package_id=pid and (vid is null or id<>vid);
   if (ch='Paquete 4' and used>=4) or (ch='Paquete 9' and used>=9) then raise exception 'El paquete ya no tiene clases disponibles'; end if;
 else pid:=null; end if;
 amt:=case ch when 'Clase suelta' then 150 when 'Primera vez' then 100 else 0 end + extra;
 if amt>0 and (method is null or method='Sin cobro') then raise exception 'Selecciona el método de pago'; end if;
 if p_action='correct' then
   update public.samah_reward_visits set channel=ch,package_id=pid,note=nullif(btrim(p_data->>'note'),''),
    app_rate=case ch when 'TotalPass' then round(120/1.16,2) when 'Fitpass' then round(80/1.16,2) end where id=vid;
   delete from public.samah_payments where visit_id=vid;
 else
   insert into public.samah_reward_visits(student,day,starts,channel,booking_id,package_id,note,app_rate,request_id)
    values(sid,d,t,ch,bid,pid,nullif(btrim(p_data->>'note'),''),case ch when 'TotalPass' then round(120/1.16,2) when 'Fitpass' then round(80/1.16,2) end,rid) returning id into vid;
 end if;
 if amt>0 then
   insert into public.samah_payments(student,visit_id,day,concept,amount,method,created_by)
    values(sid,vid,d,case when extra>0 then ch||' + actividad' else ch end,amt,method,auth.uid());
 end if;
 if bid is not null then update public.samah_bookings set access=case ch when 'TotalPass' then 'Totalpass' when 'wellhub' then 'Wellhub' when 'Cortesia' then access else ch end where id=bid; end if;
 perform public.samah_recompute_rewards(sid,date_trunc('month',d::timestamp)::date);
 insert into public.samah_desk_audit(actor,action,before_data,after_data) values(auth.uid(),p_action,case when p_action='correct' then to_jsonb(old) end,p_data||jsonb_build_object('visit_id',vid));
 return jsonb_build_object('ok',true);
end $$;
revoke execute on function public.samah_desk(text,jsonb),public.samah_recompute_rewards(uuid,date) from public,anon;
grant execute on function public.samah_desk(text,jsonb),public.samah_recompute_rewards(uuid,date) to authenticated;
savepoint desk_tests;
do $$
declare sid uuid; staff_id uuid; pid uuid:=gen_random_uuid(); rid uuid; vid uuid; r jsonb; d date:=(clock_timestamp() at time zone 'America/Mexico_City')::date-20; x record; failures integer;
begin
 select user_id into strict staff_id from public.samah_staff limit 1;
 perform set_config('request.jwt.claim.sub',staff_id::text,true);
 sid:=(public.samah_rewards('create','{"first_name":"PRUEBA","last_name":"Recepcion"}')#>>'{}')::uuid;
 perform public.samah_desk('sell',jsonb_build_object('student',sid,'channel','Paquete 4','day',d,'method','Efectivo','request_id',pid));
 perform public.samah_desk('sell',jsonb_build_object('student',sid,'channel','Paquete 4','day',d,'method','Efectivo','request_id',pid));
 if (select count(*) from public.samah_payments where student=sid)<>1 then raise exception 'Doble ingreso al reintentar venta'; end if;
 for i in 1..4 loop
  rid:=gen_random_uuid();
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Paquete 4','package_id',pid,'day',d+i,'starts','09:00','request_id',rid));
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Paquete 4','package_id',pid,'day',d+i,'starts','09:00','request_id',rid));
 end loop;
 begin
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Paquete 4','package_id',pid,'day',d+5,'starts','09:00','request_id',gen_random_uuid()));
  raise exception 'FAIL: quinta clase aceptada';
 exception when raise_exception then if sqlerrm<>'El paquete ya no tiene clases disponibles' then raise; end if; end;
 select id into vid from public.samah_reward_visits where student=sid and day=d+4;
 perform public.samah_desk('undo',jsonb_build_object('visit_id',vid));
 if (select count(*) from public.samah_reward_visits where package_id=pid)<>3 then raise exception 'No devolvió clase'; end if;
 if (select sum(amount) from public.samah_payments where student=sid)<>580 then raise exception 'Uso de paquete duplicó el ingreso'; end if;
 pid:=gen_random_uuid();
 perform public.samah_desk('sell',jsonb_build_object('student',sid,'channel','Paquete 9','day',d,'method','Tarjeta','request_id',pid));
 for i in 1..9 loop
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Paquete 9','package_id',pid,'day',d+i,'starts','10:00','request_id',gen_random_uuid()));
 end loop;
 begin
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Paquete 9','package_id',pid,'day',d+10,'starts','10:00','request_id',gen_random_uuid()));
  raise exception 'FAIL: décima clase aceptada';
 exception when raise_exception then if sqlerrm<>'El paquete ya no tiene clases disponibles' then raise; end if; end;
 pid:=gen_random_uuid();
 perform public.samah_desk('sell',jsonb_build_object('student',sid,'channel','Ilimitado','day',d-50,'method','Transferencia','request_id',pid));
 begin
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Ilimitado','package_id',pid,'day',d,'starts','11:00','request_id',gen_random_uuid()));
  raise exception 'FAIL: ilimitado vencido';
 exception when raise_exception then if sqlerrm<>'La fecha de la clase está fuera de la vigencia' then raise; end if; end;
 perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Clase suelta','day',d+1,'starts','11:00','method','Efectivo','request_id',gen_random_uuid()));
 select id into vid from public.samah_reward_visits where student=sid and day=d+1 and starts='11:00';
 perform public.samah_desk('correct',jsonb_build_object('visit_id',vid,'channel','TotalPass'));
 if exists(select 1 from public.samah_payments where visit_id=vid) then raise exception 'Corrección dejó ingreso suelto'; end if;
 if (select app_rate from public.samah_reward_visits where id=vid)<>103.45 then raise exception 'TotalPass mal calculado'; end if;
 perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','Fitpass','extra',60,'day',d+1,'starts','12:00','method','Transferencia','request_id',gen_random_uuid()));
 r:=public.samah_desk('day',jsonb_build_object('day',d+1));
 if (r->>'apps')::numeric<172.42 then raise exception 'Total de apps incorrecto'; end if;
 if not exists(select 1 from public.samah_payments where student=sid and day=d+1 and amount=60) then raise exception 'Extra incorrecto'; end if;
 -- A separate fixture prevents previous attendance from affecting reward thresholds.
 sid:=(public.samah_rewards('create','{"first_name":"PRUEBA","last_name":"Credito"}')#>>'{}')::uuid;
 d:=date_trunc('month',(clock_timestamp() at time zone 'America/Mexico_City')-interval '1 month')::date;
 for i in 0..13 loop
  perform public.samah_desk('attend',jsonb_build_object('student',sid,'channel','TotalPass','day',d+i,'starts','10:00','request_id',gen_random_uuid()));
 end loop;
 rid:=gen_random_uuid();
 perform public.samah_desk('credit',jsonb_build_object('student',sid,'month',d,'reward','TotalPass · Crédito de $200','amount',60,'request_id',rid));
 perform public.samah_desk('credit',jsonb_build_object('student',sid,'month',d,'reward','TotalPass · Crédito de $200','amount',60,'request_id',rid));
 if (select sum(amount) from public.samah_credit_uses where student=sid)<>60 then raise exception 'Crédito duplicado'; end if;
 select id into vid from public.samah_reward_visits where student=sid and day=d;
 begin
  perform public.samah_desk('correct',jsonb_build_object('visit_id',vid,'channel','Fitpass'));
  raise exception 'FAIL: corrección retiró crédito usado';
 exception when raise_exception then if sqlerrm not like 'La corrección afecta%' then raise; end if; end;
 begin
  perform public.samah_desk('credit',jsonb_build_object('student',sid,'month',d,'reward','TotalPass · Crédito de $200','amount',141,'request_id',gen_random_uuid()));
  raise exception 'FAIL: sobregiro de crédito';
 exception when raise_exception then if sqlerrm<>'El importe supera el saldo disponible' then raise; end if; end;
 perform public.samah_desk('credit',jsonb_build_object('student',sid,'month',d,'reward','TotalPass · Crédito de $200','amount',140,'request_id',gen_random_uuid()));
 if not exists(select 1 from public.samah_reward_awards where student=sid and reward='TotalPass · Crédito de $200' and redeemed_at is not null) then raise exception 'Canje completo no finalizó'; end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin
  perform public.samah_desk('day',jsonb_build_object('day',d));
  raise exception 'FAIL: acceso sin permiso';
 exception when insufficient_privilege then null; end;
end $$;
rollback to savepoint desk_tests;
commit;
select 'Instalación correcta. Pruebas de saldo, vencimiento, corrección, crédito parcial y permisos superadas. Datos de prueba revertidos.' as resultado;

