-- =====================================================================
-- RECORDA — Phase 2 migration
-- Run AFTER schema.sql. SQL Editor -> New query -> paste all -> Run.
-- Adds: business profile fields + logo, receipt numbers, notification
-- preferences, suspension, overdue alerts, team listing, error logging,
-- and everything the Developer (admin) site needs.
-- =====================================================================

-- ---------- 1. Business profile / settings ----------
alter table businesses
  add column if not exists phone text,
  add column if not exists email text,
  add column if not exists address text,
  add column if not exists receipt_footer text default 'Thank you for your business.',
  add column if not exists notification_prefs jsonb not null default '{"low_stock": true, "overdue": true}',
  add column if not exists suspended boolean not null default false,
  add column if not exists suspended_reason text;

-- ---------- 2. Receipt numbers (per business: 1, 2, 3...) ----------
alter table sales add column if not exists receipt_no integer;

create or replace function assign_receipt_no() returns trigger
language plpgsql as $$
begin
  if new.receipt_no is null then
    select coalesce(max(receipt_no), 0) + 1 into new.receipt_no
    from sales where business_id = new.business_id;
  end if;
  return new;
end $$;

drop trigger if exists sales_receipt_no on sales;
create trigger sales_receipt_no before insert on sales
  for each row execute function assign_receipt_no();

-- number any sales that were recorded before this migration
with n as (
  select id, row_number() over (partition by business_id order by created_at) as rn
  from sales where receipt_no is null
)
update sales s set receipt_no = n.rn from n where s.id = n.id;

-- ---------- 3. Platform admins (the developer site) ----------
create table if not exists platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz default now()
);
alter table platform_admins enable row level security;
drop policy if exists "admins read self" on platform_admins;
create policy "admins read self" on platform_admins for select using (user_id = auth.uid());

create or replace function is_platform_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;

create or replace function assert_admin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'forbidden'; end if;
end $$;

create table if not exists admin_audit (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid,
  admin_email text,
  action      text not null,
  target      text,
  details     jsonb,
  created_at  timestamptz default now()
);
alter table admin_audit enable row level security;
drop policy if exists "admin read audit" on admin_audit;
create policy "admin read audit" on admin_audit for select using (is_platform_admin());

-- ---------- 4. Stop owners from editing plan / suspension themselves ----------
create or replace function protect_business_admin_cols() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() is null for edits made directly in the Supabase dashboard: allow those
  if auth.uid() is not null and not is_platform_admin() then
    new.plan := old.plan;
    new.suspended := old.suspended;
    new.suspended_reason := old.suspended_reason;
    new.owner_id := old.owner_id;
  end if;
  return new;
end $$;

drop trigger if exists businesses_protect on businesses;
create trigger businesses_protect before update on businesses
  for each row execute function protect_business_admin_cols();

-- Suspended businesses become read-only
create or replace function can_write(bid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from business_members m join businesses b on b.id = m.business_id
    where m.business_id = bid and m.user_id = auth.uid()
      and m.role in ('owner', 'staff') and not b.suspended
  );
$$;

-- ---------- 5. Client error log (shows up on the developer site) ----------
create table if not exists app_errors (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid default auth.uid(),
  business_id uuid,
  page        text,
  message     text check (char_length(message) <= 1000),
  stack       text check (char_length(stack) <= 4000),
  user_agent  text check (char_length(user_agent) <= 400),
  created_at  timestamptz default now()
);
create index if not exists app_errors_created on app_errors (created_at desc);
alter table app_errors enable row level security;
drop policy if exists "insert own errors" on app_errors;
create policy "insert own errors" on app_errors for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists "admin read errors" on app_errors;
create policy "admin read errors" on app_errors for select using (is_platform_admin());

-- ---------- 6. Notifications that respect the business's preferences ----------
create or replace function notify_low_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.quantity <= new.low_stock_threshold
     and old.quantity > old.low_stock_threshold
     and coalesce((select (notification_prefs->>'low_stock')::boolean
                   from businesses where id = new.business_id), true) then
    insert into notifications (business_id, type, title, body)
    values (new.business_id, 'low_stock', new.name || ' is running low',
            'Only ' || new.quantity || ' left in stock.');
  end if;
  return new;
end $$;

-- Called when the dashboard loads: one overdue alert per customer per week
create or replace function refresh_alerts(p_business uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record; t text;
begin
  if not is_member(p_business) then return; end if;
  if not coalesce((select (notification_prefs->>'overdue')::boolean
                   from businesses where id = p_business), true) then
    return;
  end if;
  for r in select cb.name, cb.balance from customer_balances cb
           where cb.business_id = p_business and cb.overdue loop
    t := r.name || '''s payment is overdue.';
    if not exists (select 1 from notifications n
                   where n.business_id = p_business and n.type = 'overdue'
                     and n.title = t and n.created_at > now() - interval '7 days') then
      insert into notifications (business_id, type, title, body)
      values (p_business, 'overdue', t,
              'Outstanding balance: ₦' || to_char(r.balance, 'FM999,999,999,990') || '.');
    end if;
  end loop;
end $$;

-- ---------- 7. Team list (names + emails, members only) ----------
create or replace function team_members(p_business uuid)
returns table (user_id uuid, role text, full_name text, email text, joined timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_member(p_business) then raise exception 'forbidden'; end if;
  return query
  select m.user_id, m.role, p.full_name, u.email::text, m.created_at
  from business_members m
  left join profiles p on p.id = m.user_id
  left join auth.users u on u.id = m.user_id
  where m.business_id = p_business
  order by m.created_at;
end $$;

-- ---------- 8. Developer site functions (all check is_platform_admin) ----------

create or replace function admin_overview() returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  perform assert_admin();
  select json_build_object(
    'users',             (select count(*) from auth.users),
    'users_7d',          (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'users_unconfirmed', (select count(*) from auth.users where email_confirmed_at is null),
    'businesses',        (select count(*) from businesses),
    'businesses_7d',     (select count(*) from businesses where created_at > now() - interval '7 days'),
    'suspended',         (select count(*) from businesses where suspended),
    'active_30d',        (select count(distinct business_id) from sales where created_at > now() - interval '30 days'),
    'customers',         (select count(*) from customers),
    'products',          (select count(*) from products),
    'sales_count',       (select count(*) from sales),
    'sales_volume',      coalesce((select sum(total) from sales), 0),
    'sales_30d_count',   (select count(*) from sales where created_at > now() - interval '30 days'),
    'sales_30d_volume',  coalesce((select sum(total) from sales where created_at > now() - interval '30 days'), 0),
    'expenses_volume',   coalesce((select sum(amount) from expenses), 0),
    'outstanding_debt',  coalesce((select sum(total - amount_paid) from sales where total > amount_paid), 0),
    'errors_24h',        (select count(*) from app_errors where created_at > now() - interval '24 hours'),
    'db_size_bytes',     pg_database_size(current_database()),
    'storage_files',     (select count(*) from storage.objects),
    'storage_bytes',     coalesce((select sum((metadata->>'size')::bigint) from storage.objects), 0),
    'plans',             (select coalesce(json_object_agg(plan, c), '{}'::json)
                          from (select plan, count(*) as c from businesses group by plan) p)
  ) into r;
  return r;
end $$;

create or replace function admin_daily(p_days int default 30)
returns table (day date, signups bigint, new_businesses bigint, sales_count bigint, sales_volume numeric)
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  return query
  select g::date,
    (select count(*) from auth.users u where u.created_at::date = g::date),
    (select count(*) from businesses b where b.created_at::date = g::date),
    (select count(*) from sales s where s.created_at::date = g::date),
    coalesce((select sum(s2.total) from sales s2 where s2.created_at::date = g::date), 0)
  from generate_series((current_date - (p_days - 1))::timestamp, current_date::timestamp, interval '1 day') g;
end $$;

create or replace function admin_businesses()
returns table (id uuid, name text, type text, plan text, suspended boolean, suspended_reason text,
               created_at timestamptz, owner_email text, owner_name text, members bigint,
               customers bigint, products bigint, sales_count bigint, sales_volume numeric,
               last_sale timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  return query
  select b.id, b.name, b.type, b.plan, b.suspended, b.suspended_reason, b.created_at,
    u.email::text, p.full_name,
    (select count(*) from business_members m where m.business_id = b.id),
    (select count(*) from customers c where c.business_id = b.id),
    (select count(*) from products pr where pr.business_id = b.id),
    (select count(*) from sales s where s.business_id = b.id),
    coalesce((select sum(s2.total) from sales s2 where s2.business_id = b.id), 0),
    (select max(s3.created_at) from sales s3 where s3.business_id = b.id)
  from businesses b
  left join auth.users u on u.id = b.owner_id
  left join profiles p on p.id = b.owner_id
  order by b.created_at desc;
end $$;

create or replace function admin_users()
returns table (user_id uuid, email text, full_name text, phone text, created_at timestamptz,
               last_sign_in_at timestamptz, confirmed boolean, businesses bigint, is_admin boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  return query
  select u.id, u.email::text, p.full_name, p.phone, u.created_at, u.last_sign_in_at,
    (u.email_confirmed_at is not null),
    (select count(*) from business_members m where m.user_id = u.id),
    exists (select 1 from platform_admins a where a.user_id = u.id)
  from auth.users u
  left join profiles p on p.id = u.id
  order by u.created_at desc;
end $$;

create or replace function admin_activity(p_limit int default 40)
returns table (kind text, label text, at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  return query
  select x.kind, x.label, x.at from (
    select 'signup'::text as kind, coalesce(u.email::text, '') as label, u.created_at as at from auth.users u
    union all
    select 'business', b.name || ' (' || coalesce(b.type, 'n/a') || ')', b.created_at from businesses b
    union all
    select 'sale', bz.name || ' · ₦' || to_char(s.total, 'FM999,999,999,990'), s.created_at
      from sales s join businesses bz on bz.id = s.business_id
  ) x
  order by x.at desc
  limit p_limit;
end $$;

create or replace function admin_errors(p_limit int default 100)
returns table (id uuid, page text, message text, stack text, user_email text, user_agent text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  return query
  select e.id, e.page, e.message, e.stack, u.email::text, e.user_agent, e.created_at
  from app_errors e left join auth.users u on u.id = e.user_id
  order by e.created_at desc
  limit p_limit;
end $$;

create or replace function admin_clear_errors() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  delete from app_errors where true;
  insert into admin_audit (admin_id, admin_email, action, target)
  values (auth.uid(), (select u.email from auth.users u where u.id = auth.uid()), 'clear_errors', 'app_errors');
end $$;

create or replace function admin_set_plan(p_business uuid, p_plan text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  update businesses set plan = p_plan where id = p_business;
  insert into admin_audit (admin_id, admin_email, action, target, details)
  values (auth.uid(), (select u.email from auth.users u where u.id = auth.uid()),
          'set_plan', p_business::text, jsonb_build_object('plan', p_plan));
end $$;

create or replace function admin_set_suspended(p_business uuid, p_suspended boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_admin();
  update businesses
     set suspended = p_suspended,
         suspended_reason = case when p_suspended then p_reason else null end
   where id = p_business;
  insert into admin_audit (admin_id, admin_email, action, target, details)
  values (auth.uid(), (select u.email from auth.users u where u.id = auth.uid()),
          case when p_suspended then 'suspend' else 'unsuspend' end, p_business::text,
          jsonb_build_object('reason', p_reason));
end $$;

-- ---------- 9. MAKE YOURSELF THE DEVELOPER ----------
-- Register on the normal Recorda site first, then run this ONE line
-- with the email you registered with:
--
--   insert into platform_admins (user_id)
--   select id from auth.users where lower(email) = lower('YOUR_EMAIL_HERE');
