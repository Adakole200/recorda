-- =====================================================================
-- RECORDA — Supabase schema
-- Run this whole file once in Supabase → SQL Editor → New query → Run.
-- Multi-tenant: every row belongs to a business; users reach businesses
-- through business_members (roles: owner / staff / viewer).
-- =====================================================================

-- ---------- 1. Core tables ----------

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  created_at  timestamptz default now()
);

create table businesses (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id),
  name        text not null,
  type        text check (type in ('Retail','Fashion','Food','Services','Agriculture','Transport','Real Estate','Other')),
  tracking    text[] default '{}',          -- onboarding step 2 choices
  currency    text default 'NGN',
  logo_url    text,
  plan        text default 'free' check (plan in ('free','pro','business')),
  created_at  timestamptz default now()
);

create table business_members (
  business_id uuid references businesses(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,
  role        text not null default 'staff' check (role in ('owner','staff','viewer')),
  created_at  timestamptz default now(),
  primary key (business_id, user_id)
);

create table customers (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name        text not null,
  phone       text,
  address     text,
  notes       text,
  created_at  timestamptz default now()
);

create table products (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references businesses(id) on delete cascade,
  name                text not null,
  category            text,
  image_url           text,
  buying_price        numeric(14,2) default 0,
  selling_price       numeric(14,2) default 0,
  quantity            integer default 0,
  low_stock_threshold integer default 5,
  supplier            text,
  created_at          timestamptz default now()
);

-- A sale. customer_id null = walk-in customer.
create table sales (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id) on delete cascade,
  customer_id    uuid references customers(id) on delete set null,
  sale_date      date not null default current_date,
  subtotal       numeric(14,2) not null default 0,
  discount       numeric(14,2) not null default 0,
  total          numeric(14,2) not null default 0,
  amount_paid    numeric(14,2) not null default 0,
  payment_method text check (payment_method in ('Cash','Bank Transfer','POS','USSD','Credit')),
  due_date       date,                       -- for debts / overdue tracking
  note           text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now(),
  -- "Paid" / "Partially paid" / unpaid badge on the transactions page
  status         text generated always as (
                   case when amount_paid >= total then 'paid'
                        when amount_paid > 0      then 'partial'
                        else 'unpaid' end) stored
);

create table sale_items (
  id           uuid primary key default gen_random_uuid(),
  sale_id      uuid not null references sales(id) on delete cascade,
  business_id  uuid not null references businesses(id) on delete cascade,
  product_id   uuid references products(id) on delete set null,
  product_name text not null,                -- snapshot, survives product deletion
  quantity     integer not null check (quantity > 0),
  unit_price   numeric(14,2) not null,
  line_total   numeric(14,2) generated always as (quantity * unit_price) stored
);

create table expenses (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id) on delete cascade,
  amount         numeric(14,2) not null check (amount > 0),
  category       text check (category in ('Transport','Electricity','Rent','Salary','Supplies','Fuel','Internet','Marketing','Maintenance','Other')),
  description    text,
  payment_method text check (payment_method in ('Cash','Bank Transfer','POS','Mobile Money')),
  expense_date   date not null default current_date,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now()
);

-- Debt repayments ("Customer payment" on the transactions page)
create table payments (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id) on delete cascade,
  customer_id    uuid not null references customers(id) on delete cascade,
  amount         numeric(14,2) not null check (amount > 0),
  payment_method text,
  payment_date   date not null default current_date,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now()
);

-- Custom records ("Vehicles", "Tenants"...). Field definitions live in JSON:
-- fields = [{"key":"plate","label":"Plate Number","type":"Text","options":[]}, ...]
-- types: Text, Number, Currency, Date, Dropdown, Checkbox, Phone, Email, Long Text
create table record_types (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name        text not null,
  description text,
  fields      jsonb not null default '[]',
  created_at  timestamptz default now()
);

create table record_entries (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id) on delete cascade,
  record_type_id uuid not null references record_types(id) on delete cascade,
  data           jsonb not null default '{}',   -- {"plate":"ABC-123-KD","driver":"Musa"}
  created_at     timestamptz default now()
);

create table notifications (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,  -- null = everyone in business
  type        text,                                              -- low_stock, overdue, payment...
  title       text not null,
  body        text,
  is_read     boolean default false,
  created_at  timestamptz default now()
);

-- Indexes for the common lookups
create index on customers (business_id);
create index on products (business_id);
create index on sales (business_id, sale_date desc);
create index on sales (customer_id);
create index on sale_items (sale_id);
create index on expenses (business_id, expense_date desc);
create index on payments (business_id, payment_date desc);
create index on record_entries (record_type_id);
create index on notifications (business_id, created_at desc);

-- ---------- 2. Security helpers ----------

create or replace function is_member(bid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from business_members where business_id = bid and user_id = auth.uid());
$$;

create or replace function can_write(bid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from business_members
                 where business_id = bid and user_id = auth.uid() and role in ('owner','staff'));
$$;

create or replace function is_owner(bid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from business_members
                 where business_id = bid and user_id = auth.uid() and role = 'owner');
$$;

-- ---------- 3. Row Level Security ----------

alter table profiles         enable row level security;
alter table businesses       enable row level security;
alter table business_members enable row level security;
alter table notifications    enable row level security;

create policy "own profile read"   on profiles for select using (id = auth.uid());
create policy "own profile update" on profiles for update using (id = auth.uid());

create policy "members read business" on businesses for select using (is_member(id));
create policy "owner update business" on businesses for update using (is_owner(id));
create policy "owner delete business" on businesses for delete using (is_owner(id));
-- (inserts go through create_business() below)

create policy "members read team"   on business_members for select using (is_member(business_id));
create policy "owner manage team"   on business_members for all    using (is_owner(business_id)) with check (is_owner(business_id));

create policy "read own notifications" on notifications for select
  using (is_member(business_id) and (user_id is null or user_id = auth.uid()));
create policy "mark notifications read" on notifications for update
  using (is_member(business_id) and (user_id is null or user_id = auth.uid()));

-- Same four policies on every business-owned table:
-- members can read; owner + staff can write; viewers are read-only.
do $$
declare t text;
begin
  foreach t in array array['customers','products','sales','sale_items','expenses',
                           'payments','record_types','record_entries'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "members read"   on %I for select using (is_member(business_id))', t);
    execute format('create policy "writers insert" on %I for insert with check (can_write(business_id))', t);
    execute format('create policy "writers update" on %I for update using (can_write(business_id)) with check (can_write(business_id))', t);
    execute format('create policy "writers delete" on %I for delete using (can_write(business_id))', t);
  end loop;
end $$;

-- ---------- 4. Triggers ----------

-- Create a profile row whenever someone signs up
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone')
  on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function handle_new_user();

-- Low-stock notification when quantity drops to/below the threshold
create or replace function notify_low_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.quantity <= new.low_stock_threshold
     and old.quantity > old.low_stock_threshold then
    insert into notifications (business_id, type, title, body)
    values (new.business_id, 'low_stock', new.name || ' is running low',
            'Only ' || new.quantity || ' left in stock.');
  end if;
  return new;
end $$;

create trigger products_low_stock
  after update of quantity on products for each row execute function notify_low_stock();

-- ---------- 5. Functions (called from the frontend with supabase.rpc) ----------

-- Onboarding: create a business and make the caller its owner.
create or replace function create_business(p_name text, p_type text, p_tracking text[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare bid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into businesses (owner_id, name, type, tracking)
  values (auth.uid(), p_name, p_type, p_tracking) returning id into bid;
  insert into business_members (business_id, user_id, role) values (bid, auth.uid(), 'owner');
  return bid;
end $$;

-- Record a sale + its items, and reduce stock, all in one transaction.
-- p_items = [{"product_id": "uuid-or-null", "name": "Native Shirt", "qty": 2, "price": 20000}, ...]
create or replace function record_sale(
  p_business uuid, p_customer uuid, p_items jsonb,
  p_discount numeric default 0, p_method text default 'Cash',
  p_paid numeric default 0, p_date date default current_date, p_due date default null
) returns uuid language plpgsql set search_path = public as $$
declare
  sid uuid; item jsonb; sub numeric := 0;
begin
  if not can_write(p_business) then raise exception 'Not allowed'; end if;

  select coalesce(sum((i->>'qty')::numeric * (i->>'price')::numeric), 0)
    into sub from jsonb_array_elements(p_items) i;

  insert into sales (business_id, customer_id, sale_date, subtotal, discount, total,
                     amount_paid, payment_method, due_date)
  values (p_business, p_customer, p_date, sub, p_discount, greatest(sub - p_discount, 0),
          least(p_paid, greatest(sub - p_discount, 0)), p_method, p_due)
  returning id into sid;

  for item in select * from jsonb_array_elements(p_items) loop
    insert into sale_items (sale_id, business_id, product_id, product_name, quantity, unit_price)
    values (sid, p_business, nullif(item->>'product_id','')::uuid, item->>'name',
            (item->>'qty')::int, (item->>'price')::numeric);

    if nullif(item->>'product_id','') is not null then
      update products set quantity = quantity - (item->>'qty')::int
      where id = (item->>'product_id')::uuid and business_id = p_business;
    end if;
  end loop;

  return sid;
end $$;

-- Customer pays towards their debt. Applied to the oldest unpaid sales first.
-- Returns any overpayment left over (0 normally).
create or replace function record_payment(
  p_business uuid, p_customer uuid, p_amount numeric,
  p_method text default 'Cash', p_date date default current_date
) returns numeric language plpgsql set search_path = public as $$
declare remaining numeric := p_amount; s record; applied numeric;
begin
  if not can_write(p_business) then raise exception 'Not allowed'; end if;

  insert into payments (business_id, customer_id, amount, payment_method, payment_date)
  values (p_business, p_customer, p_amount, p_method, p_date);

  for s in select id, total - amount_paid as owed from sales
           where business_id = p_business and customer_id = p_customer and total > amount_paid
           order by sale_date, created_at loop
    exit when remaining <= 0;
    applied := least(remaining, s.owed);
    update sales set amount_paid = amount_paid + applied where id = s.id;
    remaining := remaining - applied;
  end loop;

  return remaining;
end $$;

-- Dashboard / reports numbers for a date range
create or replace function dashboard_summary(p_business uuid, p_from date, p_to date)
returns json language sql stable set search_path = public as $$
  select json_build_object(
    'sales_total',       coalesce((select sum(total)  from sales    where business_id = p_business and sale_date    between p_from and p_to), 0),
    'expenses_total',    coalesce((select sum(amount) from expenses where business_id = p_business and expense_date between p_from and p_to), 0),
    'outstanding_debt',  coalesce((select sum(total - amount_paid) from sales where business_id = p_business and total > amount_paid), 0),
    'low_stock_count',   (select count(*) from products where business_id = p_business and quantity <= low_stock_threshold)
  );
$$;

-- Owner adds a team member who already has a Recorda account.
create or replace function add_member_by_email(p_business uuid, p_email text, p_role text default 'staff')
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not is_owner(p_business) then raise exception 'Only the owner can add team members'; end if;
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is null then raise exception 'No Recorda account found for that email'; end if;
  insert into business_members (business_id, user_id, role) values (p_business, uid, p_role)
  on conflict (business_id, user_id) do update set role = excluded.role;
end $$;

-- ---------- 6. Views (security_invoker = RLS still applies) ----------

-- Debts page: what each customer owes
create view customer_balances with (security_invoker = on) as
select c.id as customer_id, c.business_id, c.name, c.phone,
       coalesce(sum(s.total - s.amount_paid) filter (where s.total > s.amount_paid), 0) as balance,
       min(s.due_date) filter (where s.total > s.amount_paid) as oldest_due,
       coalesce(bool_or(s.due_date < current_date and s.total > s.amount_paid), false) as overdue
from customers c
left join sales s on s.customer_id = c.id
group by c.id;

-- Transactions page: sales + expenses + debt payments in one feed
create view transactions with (security_invoker = on) as
select id, business_id, 'sale'::text as kind, sale_date as txn_date, 'Sale'::text as title,
       total as amount, payment_method, status, customer_id, created_at from sales
union all
select id, business_id, 'expense', expense_date, coalesce(description, category),
       amount, payment_method, 'paid', null::uuid, created_at from expenses
union all
select id, business_id, 'payment', payment_date, 'Debt repayment',
       amount, payment_method, 'paid', customer_id, created_at from payments;

-- ---------- 7. Storage (product images, logos, receipts) ----------
-- Files are stored under  <business_id>/<filename>

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict do nothing;

create policy "product images upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and can_write(((storage.foldername(name))[1])::uuid));
create policy "product images update" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and can_write(((storage.foldername(name))[1])::uuid));
create policy "product images delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and can_write(((storage.foldername(name))[1])::uuid));
