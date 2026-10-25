-- =============================================================================
-- Stock: E-Commerce & Smart Inventory - Step 1: initial schema (multi-shop)
-- Target: Supabase (PostgreSQL 15+). Run with `supabase db push` or paste into
-- the SQL editor.
--
-- Core ideas
--   * Multi-tenant: one database serves many shops. Every business row carries
--     shop_id, foreign keys are composite (shop_id, id) so a row can never
--     point at another shop's data, and RLS scopes every read/write to the
--     shops the user belongs to.
--   * People: every auth user has a global profile (customers can buy from any
--     shop). Staff access is granted per shop through shop_members with a role
--     (staff < manager < owner). Platform admins (your managed-service team)
--     act as owner in every shop.
--   * Money is stored as integer minor units (cents).
--   * Every product has >= 1 variant; stock, SKU, barcode and price live on the
--     variant. A "simple" product just has one default variant.
--   * inventory_items holds the current counts (on_hand, reserved, available).
--     The ONLY way to change those counts is to INSERT into the append-only
--     inventory_movements ledger. A trigger applies the delta under a row lock
--     and CHECK constraints make overselling impossible (foundation for Step 2).
--   * Orders and sales are created by SECURITY DEFINER functions (Step 2).
--
-- Bootstrap: sign up, then from the SQL editor make yourself a platform admin:
--   update public.profiles set is_platform_admin = true where email = 'you@example.com';
-- Shop owners create shops through public.create_shop(name, slug).
-- =============================================================================

create schema if not exists private;  -- helpers + internal tables, not exposed through the API
grant usage on schema private to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
-- Declared lowest -> highest so `role >= 'manager'` works as a privilege check.
create type public.shop_role          as enum ('staff', 'manager', 'owner');
create type public.shop_status        as enum ('active', 'suspended');
create type public.product_status     as enum ('draft', 'active', 'archived');
create type public.order_channel      as enum ('online', 'pos');
create type public.order_status       as enum (
  'pending',           -- online order placed, stock reserved, awaiting payment
  'confirmed',         -- paid (or pay-on-pickup accepted); stock committed
  'packed',
  'shipped',
  'ready_for_pickup',
  'completed',         -- delivered / collected / POS sale done
  'cancelled',
  'refunded'
);
create type public.payment_status     as enum ('unpaid', 'paid', 'partially_refunded', 'refunded', 'failed');
create type public.payment_method     as enum ('cash', 'card', 'mobile_money', 'online', 'other');
create type public.fulfillment_method as enum ('delivery', 'pickup', 'in_store');
create type public.reservation_status as enum ('active', 'committed', 'released', 'expired');
create type public.movement_reason    as enum (
  'restock',              -- goods received from supplier
  'sale_online',          -- reservation committed: on_hand and reserved both drop
  'sale_pos',             -- in-store quick deduct
  'return',               -- customer return back to sellable stock
  'damage',               -- written off (broken, expired, stolen)
  'adjustment',           -- manual correction
  'stocktake',            -- delta from a physical count
  'reservation',          -- online checkout holds stock
  'reservation_release'   -- hold released (cancelled / expired)
);
create type public.alert_status as enum ('open', 'acknowledged', 'resolved');

-- -----------------------------------------------------------------------------
-- Generic helpers
-- -----------------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function private.is_privileged_session()
returns boolean language sql stable set search_path = '' as $$
  select current_user in ('postgres', 'service_role', 'supabase_admin')
$$;

-- -----------------------------------------------------------------------------
-- Profiles (global, 1:1 with auth.users)
-- -----------------------------------------------------------------------------
create table public.profiles (
  id                uuid primary key references auth.users (id) on delete cascade,
  email             text,
  full_name         text,
  phone             text,
  is_platform_admin boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create trigger profiles_updated_at before update on public.profiles
  for each row execute function private.set_updated_at();

create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name, phone)
  values (new.id, new.email,
          new.raw_user_meta_data ->> 'full_name',
          new.raw_user_meta_data ->> 'phone')
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- Platform admin can only be granted from the SQL editor / service role.
create or replace function private.guard_profile_admin_flag()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.is_platform_admin is distinct from old.is_platform_admin
     and not private.is_privileged_session() then
    raise exception 'is_platform_admin can only be changed by the service role'
      using errcode = '42501';
  end if;
  return new;
end $$;

create trigger profiles_guard_admin_flag before update on public.profiles
  for each row execute function private.guard_profile_admin_flag();

-- -----------------------------------------------------------------------------
-- Shops (tenants) and membership
-- -----------------------------------------------------------------------------
create table public.shops (
  id                          uuid primary key default gen_random_uuid(),
  name                        text not null check (length(trim(name)) > 0),
  slug                        text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),  -- storefront URL
  status                      public.shop_status not null default 'active',
  currency                    char(3) not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  timezone                    text    not null default 'UTC',
  contact_email               text,
  contact_phone               text,
  address                     jsonb check (address is null or jsonb_typeof(address) = 'object'),
  logo_path                   text,
  reservation_ttl_minutes     integer not null default 15 check (reservation_ttl_minutes between 1 and 1440),
  default_low_stock_threshold integer not null default 5  check (default_low_stock_threshold >= 0),
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create trigger shops_updated_at before update on public.shops
  for each row execute function private.set_updated_at();

create table public.shop_members (
  shop_id    uuid not null references public.shops (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.shop_role not null default 'staff',
  created_at timestamptz not null default now(),
  primary key (shop_id, user_id)
);
create index shop_members_user_idx on public.shop_members (user_id);

-- Per-shop order number counter (internal, not reachable through the API).
create table private.order_counters (
  shop_id     uuid primary key references public.shops (id) on delete cascade,
  next_number bigint not null default 1001
);

create or replace function private.create_shop_counter()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into private.order_counters (shop_id) values (new.id);
  return new;
end $$;

create trigger shops_create_counter after insert on public.shops
  for each row execute function private.create_shop_counter();

-- Access helpers used by RLS. They return arrays so policies can use
-- `shop_id in (select private.shops_where_role('staff'))`, which Postgres
-- evaluates once per statement instead of once per row.
create or replace function private.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p.is_platform_admin from public.profiles p where p.id = auth.uid()), false)
$$;

create or replace function private.shops_where_role(min_role public.shop_role)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select s.id from public.shops s where private.is_platform_admin()
  union
  select m.shop_id from public.shop_members m
   where m.user_id = auth.uid() and m.role >= min_role
$$;

create or replace function private.has_shop_role(target_shop uuid, min_role public.shop_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_platform_admin()
      or exists (select 1 from public.shop_members m
                  where m.shop_id = target_shop and m.user_id = auth.uid() and m.role >= min_role)
$$;

create or replace function private.active_shop_ids()
returns setof uuid language sql stable security definer set search_path = '' as $$
  select s.id from public.shops s where s.status = 'active'
$$;

-- Owners can't remove or demote the last owner of a shop.
create or replace function private.guard_last_owner()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.role = 'owner'
     and (tg_op = 'DELETE' or new.role <> 'owner')
     and not exists (select 1 from public.shop_members m
                      where m.shop_id = old.shop_id and m.role = 'owner' and m.user_id <> old.user_id)
     and exists (select 1 from public.shops s where s.id = old.shop_id)  -- allow shop deletion cascade
  then
    raise exception 'A shop must keep at least one owner' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $$;

create trigger shop_members_guard_last_owner before update or delete on public.shop_members
  for each row execute function private.guard_last_owner();

-- Self-service onboarding: creates the shop and makes the caller its owner.
create or replace function public.create_shop(p_name text, p_slug text, p_currency char(3) default 'USD')
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to create a shop' using errcode = '42501';
  end if;
  insert into public.shops (name, slug, currency) values (p_name, p_slug, p_currency)
  returning id into new_id;
  insert into public.shop_members (shop_id, user_id, role) values (new_id, auth.uid(), 'owner');
  return new_id;
end $$;

-- -----------------------------------------------------------------------------
-- Catalog: categories, products, variants, images
-- -----------------------------------------------------------------------------
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  parent_id   uuid,
  name        text not null check (length(trim(name)) > 0),
  slug        text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description text,
  image_path  text,                       -- Supabase Storage object path
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (shop_id, id),
  unique (shop_id, slug),
  foreign key (shop_id, parent_id) references public.categories (shop_id, id) on delete set null (parent_id),
  check (parent_id is distinct from id)
);
create index categories_parent_idx on public.categories (shop_id, parent_id);

create trigger categories_updated_at before update on public.categories
  for each row execute function private.set_updated_at();

create table public.products (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  category_id uuid,
  name        text not null check (length(trim(name)) > 0),
  slug        text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description text,
  status      public.product_status not null default 'draft',
  is_featured boolean not null default false,
  search      tsvector generated always as (
                to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(description, ''))
              ) stored,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (shop_id, id),
  unique (shop_id, slug),
  foreign key (shop_id, category_id) references public.categories (shop_id, id) on delete set null (category_id)
);
create index products_category_idx on public.products (shop_id, category_id);
create index products_status_idx   on public.products (shop_id, status, is_featured);
create index products_search_idx   on public.products using gin (search);

create trigger products_updated_at before update on public.products
  for each row execute function private.set_updated_at();

create table public.product_variants (
  id                     uuid primary key default gen_random_uuid(),
  shop_id                uuid not null references public.shops (id) on delete cascade,
  product_id             uuid not null,
  sku                    text not null check (length(trim(sku)) > 0),
  barcode                text,                             -- for POS scanning
  name                   text not null default 'Default',  -- e.g. 'Red / M'
  options                jsonb not null default '{}'::jsonb check (jsonb_typeof(options) = 'object'),
  price_cents            integer not null check (price_cents >= 0),
  compare_at_price_cents integer check (compare_at_price_cents is null or compare_at_price_cents > price_cents),
  is_active              boolean not null default true,
  sort_order             integer not null default 0,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (shop_id, id),
  unique (shop_id, sku),
  unique (shop_id, barcode),
  foreign key (shop_id, product_id) references public.products (shop_id, id) on delete cascade
);
create index product_variants_product_idx on public.product_variants (product_id, sort_order);

create trigger product_variants_updated_at before update on public.product_variants
  for each row execute function private.set_updated_at();

create table public.product_images (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  product_id   uuid not null,
  variant_id   uuid,
  storage_path text not null,
  alt_text     text,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  foreign key (shop_id, product_id) references public.products (shop_id, id) on delete cascade,
  foreign key (shop_id, variant_id) references public.product_variants (shop_id, id) on delete set null (variant_id)
);
create index product_images_product_idx on public.product_images (product_id, sort_order);
create index product_images_variant_idx on public.product_images (variant_id);

-- -----------------------------------------------------------------------------
-- Inventory: current counts per variant
-- -----------------------------------------------------------------------------
create table public.inventory_items (
  variant_id          uuid primary key,
  shop_id             uuid not null references public.shops (id) on delete cascade,
  on_hand             integer not null default 0,
  reserved            integer not null default 0,
  available           integer generated always as (on_hand - reserved) stored,
  low_stock_threshold integer not null default 5 check (low_stock_threshold >= 0),
  cost_cents          integer check (cost_cents is null or cost_cents >= 0),  -- staff-only, hence here
  bin_location        text,
  version             bigint  not null default 0,  -- bumps on every movement (optimistic UI)
  updated_at          timestamptz not null default now(),
  foreign key (shop_id, variant_id) references public.product_variants (shop_id, id) on delete cascade,
  constraint inventory_on_hand_nonnegative   check (on_hand >= 0),
  constraint inventory_reserved_nonnegative  check (reserved >= 0),
  constraint inventory_reserved_within_stock check (reserved <= on_hand)
);
create index inventory_items_shop_available_idx on public.inventory_items (shop_id, available);

create trigger inventory_items_updated_at before update on public.inventory_items
  for each row execute function private.set_updated_at();

-- Every new variant gets an inventory row at zero.
create or replace function private.create_inventory_item()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.inventory_items (variant_id, shop_id, low_stock_threshold)
  select new.id, new.shop_id, s.default_low_stock_threshold
    from public.shops s where s.id = new.shop_id
  on conflict (variant_id) do nothing;
  return new;
end $$;

create trigger product_variants_create_inventory after insert on public.product_variants
  for each row execute function private.create_inventory_item();

-- Block direct edits of quantities; they must come from the ledger trigger
-- (which runs one trigger level deeper).
create or replace function private.guard_inventory_quantities()
returns trigger language plpgsql set search_path = '' as $$
begin
  if pg_trigger_depth() < 2 then
    if tg_op = 'INSERT' and (new.on_hand <> 0 or new.reserved <> 0) then
      raise exception 'Inventory starts at zero; record stock via inventory_movements'
        using errcode = '42501';
    elsif tg_op = 'UPDATE' and (new.on_hand, new.reserved) is distinct from (old.on_hand, old.reserved) then
      raise exception 'Stock quantities can only change through inventory_movements'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create trigger inventory_items_guard_quantities before insert or update on public.inventory_items
  for each row execute function private.guard_inventory_quantities();

-- shop_id is fixed for life on every tenant row.
create or replace function private.forbid_shop_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.shop_id is distinct from old.shop_id then
    raise exception 'shop_id cannot change' using errcode = '42501';
  end if;
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- Orders
-- -----------------------------------------------------------------------------
create table public.orders (
  id                 uuid primary key default gen_random_uuid(),
  shop_id            uuid not null references public.shops (id) on delete restrict,
  order_number       bigint not null,                       -- per shop, shown as #1001
  channel            public.order_channel      not null,
  status             public.order_status       not null default 'pending',
  payment_status     public.payment_status     not null default 'unpaid',
  payment_method     public.payment_method,
  payment_reference  text,                                  -- PSP charge / receipt id
  fulfillment_method public.fulfillment_method not null,

  customer_id        uuid references public.profiles (id) on delete set null,  -- null = guest / walk-in
  customer_email     text,
  customer_name      text,
  customer_phone     text,
  shipping_address   jsonb check (shipping_address is null or jsonb_typeof(shipping_address) = 'object'),
  cashier_id         uuid references public.profiles (id) on delete set null,  -- POS staff member

  currency           char(3) not null check (currency ~ '^[A-Z]{3}$'),
  subtotal_cents     integer not null default 0 check (subtotal_cents >= 0),  -- maintained by trigger
  discount_cents     integer not null default 0 check (discount_cents >= 0),
  shipping_cents     integer not null default 0 check (shipping_cents >= 0),
  tax_cents          integer not null default 0 check (tax_cents >= 0),
  total_cents        integer generated always as
                       (subtotal_cents - discount_cents + shipping_cents + tax_cents) stored,

  tracking_token     uuid not null default gen_random_uuid() unique,  -- guest tracking link secret
  carrier            text,
  tracking_number    text,
  idempotency_key    text,                                            -- blocks double-submit
  notes              text,

  confirmed_at       timestamptz,
  completed_at       timestamptz,
  cancelled_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  unique (shop_id, id),
  unique (shop_id, order_number),
  unique (shop_id, idempotency_key),
  constraint orders_pos_is_in_store check ((channel = 'pos') = (fulfillment_method = 'in_store')),
  constraint orders_online_has_contact check (channel = 'pos' or customer_email is not null),
  constraint orders_delivery_has_address check (fulfillment_method <> 'delivery' or shipping_address is not null),
  constraint orders_total_nonnegative check (subtotal_cents - discount_cents + shipping_cents + tax_cents >= 0)
);
create index orders_shop_status_idx  on public.orders (shop_id, status, created_at desc);
create index orders_shop_channel_idx on public.orders (shop_id, channel, created_at desc);
create index orders_customer_idx     on public.orders (customer_id, created_at desc);
create index orders_email_idx        on public.orders (shop_id, lower(customer_email));
create index orders_cashier_idx      on public.orders (cashier_id);

create trigger orders_updated_at before update on public.orders
  for each row execute function private.set_updated_at();
create trigger orders_fixed_shop before update of shop_id on public.orders
  for each row execute function private.forbid_shop_change();

-- Per-shop order number, currency and other defaults.
create or replace function private.order_defaults()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update private.order_counters c
     set next_number = c.next_number + 1
   where c.shop_id = new.shop_id
  returning c.next_number - 1 into new.order_number;

  if new.currency is null then
    select s.currency into new.currency from public.shops s where s.id = new.shop_id;
  end if;
  if new.channel = 'pos' and new.cashier_id is null then
    new.cashier_id := auth.uid();
  end if;
  if new.status = 'confirmed' then new.confirmed_at := coalesce(new.confirmed_at, now()); end if;
  if new.status = 'completed' then
    new.confirmed_at := coalesce(new.confirmed_at, now());
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  return new;
end $$;

create trigger orders_defaults before insert on public.orders
  for each row execute function private.order_defaults();

-- Allowed status transitions (a POS sale is inserted directly as 'completed').
create or replace function private.order_transition_allowed(from_s public.order_status, to_s public.order_status)
returns boolean language sql immutable set search_path = '' as $$
  select case from_s
    when 'pending'          then to_s in ('confirmed', 'cancelled')
    when 'confirmed'        then to_s in ('packed', 'ready_for_pickup', 'completed', 'cancelled', 'refunded')
    when 'packed'           then to_s in ('shipped', 'ready_for_pickup', 'cancelled')
    when 'shipped'          then to_s in ('completed')
    when 'ready_for_pickup' then to_s in ('completed', 'cancelled')
    when 'completed'        then to_s in ('refunded')
    else false
  end
$$;

create or replace function private.validate_order_status()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if not private.order_transition_allowed(old.status, new.status) then
      raise exception 'Order % cannot move from % to %', old.order_number, old.status, new.status
        using errcode = '23514';
    end if;
    case new.status
      when 'confirmed' then new.confirmed_at := coalesce(new.confirmed_at, now());
      when 'completed' then new.completed_at := now();
      when 'cancelled' then new.cancelled_at := now();
      else null;
    end case;
  end if;
  return new;
end $$;

create trigger orders_validate_status before update of status on public.orders
  for each row execute function private.validate_order_status();

-- Status timeline (powers customer order tracking + audit).
create table public.order_status_history (
  id          bigint generated always as identity primary key,
  shop_id     uuid not null,
  order_id    uuid not null,
  from_status public.order_status,
  to_status   public.order_status not null,
  changed_by  uuid,   -- auth user id; no FK so history survives user deletion
  note        text,
  created_at  timestamptz not null default now(),
  foreign key (shop_id, order_id) references public.orders (shop_id, id) on delete cascade
);
create index order_status_history_order_idx on public.order_status_history (order_id, created_at);

create or replace function private.log_order_status()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history (shop_id, order_id, from_status, to_status, changed_by)
    values (new.shop_id, new.id, case when tg_op = 'UPDATE' then old.status end, new.status, auth.uid());
  end if;
  return null;
end $$;

create trigger orders_log_status after insert or update of status on public.orders
  for each row execute function private.log_order_status();

-- -----------------------------------------------------------------------------
-- Order items (price/name snapshots so later catalog edits don't rewrite history)
-- -----------------------------------------------------------------------------
create table public.order_items (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null,
  order_id         uuid not null,
  variant_id       uuid not null,
  product_name     text not null,
  variant_name     text not null,
  sku              text not null,
  unit_price_cents integer not null check (unit_price_cents >= 0),
  quantity         integer not null check (quantity > 0),
  line_total_cents integer generated always as (unit_price_cents * quantity) stored,
  created_at       timestamptz not null default now(),
  unique (order_id, variant_id),
  foreign key (shop_id, order_id)   references public.orders (shop_id, id) on delete cascade,
  foreign key (shop_id, variant_id) references public.product_variants (shop_id, id) on delete restrict
);
create index order_items_variant_idx on public.order_items (variant_id);

-- Fill shop_id and snapshot columns from the order / catalog when left null.
create or replace function private.order_item_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v record;
begin
  if new.shop_id is null then
    select o.shop_id into new.shop_id from public.orders o where o.id = new.order_id;
  end if;

  select p.name as product_name, pv.name as variant_name, pv.sku, pv.price_cents
    into v
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
   where pv.id = new.variant_id and pv.shop_id = new.shop_id;

  if not found then
    raise exception 'Variant % does not belong to this order''s shop', new.variant_id
      using errcode = '23503';
  end if;

  new.product_name     := coalesce(new.product_name, v.product_name);
  new.variant_name     := coalesce(new.variant_name, v.variant_name);
  new.sku              := coalesce(new.sku, v.sku);
  new.unit_price_cents := coalesce(new.unit_price_cents, v.price_cents);
  return new;
end $$;

create trigger order_items_snapshot before insert on public.order_items
  for each row execute function private.order_item_snapshot();

-- Keep orders.subtotal_cents in sync with its items.
create or replace function private.recalc_order_subtotal()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  target uuid := coalesce(new.order_id, old.order_id);
begin
  update public.orders o
     set subtotal_cents = coalesce((select sum(i.line_total_cents) from public.order_items i
                                     where i.order_id = target), 0)
   where o.id = target;
  return null;
end $$;

create trigger order_items_recalc_subtotal after insert or update or delete on public.order_items
  for each row execute function private.recalc_order_subtotal();

-- -----------------------------------------------------------------------------
-- Stock reservations (online checkout holds; Step 2 creates/commits/releases)
-- -----------------------------------------------------------------------------
create table public.stock_reservations (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null,
  order_id    uuid not null,
  variant_id  uuid not null,
  quantity    integer not null check (quantity > 0),
  status      public.reservation_status not null default 'active',
  expires_at  timestamptz not null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  unique (shop_id, id),
  unique (order_id, variant_id),
  foreign key (shop_id, order_id)   references public.orders (shop_id, id) on delete restrict,
  foreign key (shop_id, variant_id) references public.product_variants (shop_id, id) on delete restrict,
  check ((status = 'active') = (resolved_at is null))
);
create index stock_reservations_active_expiry_idx  on public.stock_reservations (expires_at) where status = 'active';
create index stock_reservations_variant_active_idx on public.stock_reservations (variant_id) where status = 'active';

-- -----------------------------------------------------------------------------
-- Inventory ledger (append-only audit log; the single source of stock changes)
-- -----------------------------------------------------------------------------
create table public.inventory_movements (
  id              bigint generated always as identity primary key,
  shop_id         uuid not null,
  variant_id      uuid not null,
  reason          public.movement_reason not null,
  on_hand_delta   integer not null default 0,
  reserved_delta  integer not null default 0,
  on_hand_after   integer not null,   -- filled by trigger
  reserved_after  integer not null,   -- filled by trigger
  order_id        uuid,
  reservation_id  uuid,
  actor_id        uuid default auth.uid(),  -- no FK: the log must outlive staff accounts
  note            text,
  idempotency_key text,                     -- lets POS/webhooks retry safely
  created_at      timestamptz not null default now(),

  unique (shop_id, idempotency_key),
  foreign key (shop_id, variant_id)     references public.product_variants (shop_id, id) on delete restrict,
  foreign key (shop_id, order_id)       references public.orders (shop_id, id) on delete restrict,
  foreign key (shop_id, reservation_id) references public.stock_reservations (shop_id, id) on delete restrict,

  -- Each reason has a fixed shape, so the log can't record nonsense.
  constraint movement_shape check (
    case reason
      when 'restock'             then on_hand_delta > 0 and reserved_delta = 0
      when 'return'              then on_hand_delta > 0 and reserved_delta = 0
      when 'sale_pos'            then on_hand_delta < 0 and reserved_delta = 0
      when 'damage'              then on_hand_delta < 0 and reserved_delta = 0
      when 'adjustment'          then on_hand_delta <> 0 and reserved_delta = 0
      when 'stocktake'           then on_hand_delta <> 0 and reserved_delta = 0
      when 'reservation'         then on_hand_delta = 0 and reserved_delta > 0
      when 'reservation_release' then on_hand_delta = 0 and reserved_delta < 0
      when 'sale_online'         then on_hand_delta < 0 and reserved_delta = on_hand_delta
    end
  ),
  constraint movement_sales_need_order check (
    reason not in ('sale_pos', 'sale_online', 'reservation', 'reservation_release') or order_id is not null
  )
);
create index inventory_movements_variant_idx on public.inventory_movements (variant_id, created_at desc);
create index inventory_movements_order_idx   on public.inventory_movements (order_id) where order_id is not null;
create index inventory_movements_shop_idx    on public.inventory_movements (shop_id, created_at desc);
create index inventory_movements_reason_idx  on public.inventory_movements (shop_id, reason, created_at desc);

-- Apply the delta to inventory_items. The UPDATE takes a row lock on the
-- variant, so concurrent sales of the same item queue up instead of racing,
-- and the CHECK constraints on inventory_items reject any oversell
-- (SQLSTATE 23514, constraint name tells you which rule failed).
create or replace function private.apply_inventory_movement()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.inventory_items i
     set on_hand  = i.on_hand  + new.on_hand_delta,
         reserved = i.reserved + new.reserved_delta,
         version  = i.version  + 1
   where i.variant_id = new.variant_id and i.shop_id = new.shop_id
  returning i.on_hand, i.reserved into new.on_hand_after, new.reserved_after;

  if not found then
    raise exception 'No inventory record for variant % in shop %', new.variant_id, new.shop_id
      using errcode = 'P0002';
  end if;
  return new;
end $$;

create trigger inventory_movements_apply before insert on public.inventory_movements
  for each row execute function private.apply_inventory_movement();

create or replace function private.forbid_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end $$;

create trigger inventory_movements_immutable before update or delete on public.inventory_movements
  for each row execute function private.forbid_change();
create trigger order_status_history_immutable before update on public.order_status_history
  for each row execute function private.forbid_change();

-- -----------------------------------------------------------------------------
-- Low-stock alerts (opened/resolved automatically; dashboard subscribes via Realtime)
-- -----------------------------------------------------------------------------
create table public.low_stock_alerts (
  id                bigint generated always as identity primary key,
  shop_id           uuid not null,
  variant_id        uuid not null,
  status            public.alert_status not null default 'open',
  available_at_open integer not null,
  threshold         integer not null,
  acknowledged_by   uuid references public.profiles (id) on delete set null,
  acknowledged_at   timestamptz,
  resolved_at       timestamptz,
  created_at        timestamptz not null default now(),
  foreign key (shop_id, variant_id) references public.product_variants (shop_id, id) on delete cascade
);
-- At most one unresolved alert per variant.
create unique index low_stock_alerts_one_open_idx on public.low_stock_alerts (variant_id)
  where status in ('open', 'acknowledged');
create index low_stock_alerts_shop_status_idx on public.low_stock_alerts (shop_id, status, created_at desc);

create or replace function private.sync_low_stock_alert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.available <= new.low_stock_threshold then
    insert into public.low_stock_alerts (shop_id, variant_id, available_at_open, threshold)
    values (new.shop_id, new.variant_id, new.available, new.low_stock_threshold)
    on conflict (variant_id) where status in ('open', 'acknowledged') do nothing;
  else
    update public.low_stock_alerts a
       set status = 'resolved', resolved_at = now()
     where a.variant_id = new.variant_id
       and a.status in ('open', 'acknowledged');
  end if;
  return null;
end $$;

create trigger inventory_items_low_stock
  after update of on_hand, reserved, low_stock_threshold on public.inventory_items
  for each row execute function private.sync_low_stock_alert();

-- shop_id never changes on tenant rows (orders handled above).
create trigger categories_fixed_shop       before update of shop_id on public.categories       for each row execute function private.forbid_shop_change();
create trigger products_fixed_shop         before update of shop_id on public.products         for each row execute function private.forbid_shop_change();
create trigger product_variants_fixed_shop before update of shop_id on public.product_variants for each row execute function private.forbid_shop_change();
create trigger product_images_fixed_shop   before update of shop_id on public.product_images   for each row execute function private.forbid_shop_change();
create trigger inventory_items_fixed_shop  before update of shop_id on public.inventory_items  for each row execute function private.forbid_shop_change();
create trigger low_stock_alerts_fixed_shop before update of shop_id on public.low_stock_alerts for each row execute function private.forbid_shop_change();
create trigger shop_members_fixed_shop     before update of shop_id on public.shop_members     for each row execute function private.forbid_shop_change();

-- -----------------------------------------------------------------------------
-- Read models
-- -----------------------------------------------------------------------------
-- Admin dashboard grid. security_invoker => caller's RLS applies (own shops only).
create view public.inventory_overview with (security_invoker = true) as
select
  pv.shop_id,
  pv.id               as variant_id,
  p.id                as product_id,
  p.name              as product_name,
  pv.name             as variant_name,
  pv.sku,
  pv.barcode,
  c.name              as category_name,
  p.status            as product_status,
  pv.is_active        as variant_active,
  pv.price_cents,
  i.cost_cents,
  i.on_hand,
  i.reserved,
  i.available,
  i.low_stock_threshold,
  (i.available <= i.low_stock_threshold) as is_low_stock,
  i.version,
  i.updated_at        as stock_updated_at
from public.product_variants pv
join public.products p        on p.id = pv.product_id
join public.inventory_items i on i.variant_id = pv.id
left join public.categories c on c.id = p.category_id;

-- Storefront availability. Deliberately runs as the view owner so shoppers can
-- see "in stock / only N left" without being able to read inventory_items
-- (counts, cost, bin location). Exposes nothing else.
create view public.storefront_availability with (security_barrier = true) as
select
  pv.shop_id,
  pv.id                       as variant_id,
  pv.product_id,
  (i.available > 0)           as in_stock,
  case when i.available > 0 and i.available <= i.low_stock_threshold
       then i.available end   as only_left
from public.product_variants pv
join public.products p        on p.id = pv.product_id
join public.shops s           on s.id = pv.shop_id
join public.inventory_items i on i.variant_id = pv.id
where s.status = 'active' and p.status = 'active' and pv.is_active;

-- Guest order tracking: order number + secret token from the confirmation email.
create or replace function public.track_order(p_order_number bigint, p_tracking_token uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'shop',               jsonb_build_object('name', s.name, 'slug', s.slug),
    'order_number',       o.order_number,
    'status',             o.status,
    'payment_status',     o.payment_status,
    'fulfillment_method', o.fulfillment_method,
    'currency',           o.currency,
    'total_cents',        o.total_cents,
    'carrier',            o.carrier,
    'tracking_number',    o.tracking_number,
    'created_at',         o.created_at,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                 'product_name', i.product_name, 'variant_name', i.variant_name,
                 'quantity', i.quantity, 'line_total_cents', i.line_total_cents)
               order by i.created_at)
               from public.order_items i where i.order_id = o.id), '[]'::jsonb),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object(
                 'status', h.to_status, 'at', h.created_at) order by h.created_at)
               from public.order_status_history h where h.order_id = o.id), '[]'::jsonb)
  )
  from public.orders o
  join public.shops s on s.id = o.shop_id
  where o.order_number = p_order_number and o.tracking_token = p_tracking_token
$$;

-- -----------------------------------------------------------------------------
-- Function privileges
-- -----------------------------------------------------------------------------
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_platform_admin()                          to anon, authenticated, service_role;
grant execute on function private.shops_where_role(public.shop_role)           to anon, authenticated, service_role;
grant execute on function private.has_shop_role(uuid, public.shop_role)        to anon, authenticated, service_role;
grant execute on function private.active_shop_ids()                            to anon, authenticated, service_role;
grant execute on function private.is_privileged_session()                      to anon, authenticated, service_role;
revoke all on function public.track_order(bigint, uuid) from public;
grant execute on function public.track_order(bigint, uuid) to anon, authenticated, service_role;
revoke all on function public.create_shop(text, text, char) from public, anon;
grant execute on function public.create_shop(text, text, char) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Row Level Security
--   shopper  : active shops' active catalog, own profile, own orders (any shop)
--   staff    : + read everything in their shop, update orders, ack alerts
--   manager  : + edit catalog, inventory settings, manual stock movements
--   owner    : + shop settings and members
--   platform admin : owner in every shop
-- Set-returning helpers are used as `in (select ...)` so they run once per statement.
-- -----------------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.shops                enable row level security;
alter table public.shop_members         enable row level security;
alter table public.categories           enable row level security;
alter table public.products             enable row level security;
alter table public.product_variants     enable row level security;
alter table public.product_images       enable row level security;
alter table public.inventory_items      enable row level security;
alter table public.orders               enable row level security;
alter table public.order_items          enable row level security;
alter table public.order_status_history enable row level security;
alter table public.stock_reservations   enable row level security;
alter table public.inventory_movements  enable row level security;
alter table public.low_stock_alerts     enable row level security;

-- profiles
create policy "read own profile; staff read their customers and team" on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or (select private.is_platform_admin())
    or exists (select 1 from public.shop_members m
                where m.user_id = profiles.id
                  and m.shop_id in (select private.shops_where_role('staff')))
    or exists (select 1 from public.orders o
                where o.customer_id = profiles.id
                  and o.shop_id in (select private.shops_where_role('staff'))));
create policy "update own profile" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- shops: public storefront info for active shops; members see their own even if suspended
create policy "active shops are public" on public.shops
  for select to anon, authenticated
  using (status = 'active' or id in (select private.shops_where_role('staff')));
create policy "owners edit their shop" on public.shops
  for update to authenticated
  using (id in (select private.shops_where_role('owner')))
  with check (id in (select private.shops_where_role('owner')));

-- shop_members
create policy "members see their shop's team" on public.shop_members
  for select to authenticated
  using (user_id = (select auth.uid()) or shop_id in (select private.shops_where_role('staff')));
create policy "owners manage their team" on public.shop_members
  for all to authenticated
  using (shop_id in (select private.shops_where_role('owner')))
  with check (shop_id in (select private.shops_where_role('owner')));

-- categories
create policy "active categories of active shops are public" on public.categories
  for select to anon, authenticated
  using ((is_active and shop_id in (select private.active_shop_ids()))
         or shop_id in (select private.shops_where_role('staff')));
create policy "managers manage categories" on public.categories
  for all to authenticated
  using (shop_id in (select private.shops_where_role('manager')))
  with check (shop_id in (select private.shops_where_role('manager')));

-- products
create policy "active products of active shops are public" on public.products
  for select to anon, authenticated
  using ((status = 'active' and shop_id in (select private.active_shop_ids()))
         or shop_id in (select private.shops_where_role('staff')));
create policy "managers manage products" on public.products
  for all to authenticated
  using (shop_id in (select private.shops_where_role('manager')))
  with check (shop_id in (select private.shops_where_role('manager')));

-- product_variants
create policy "active variants of active products are public" on public.product_variants
  for select to anon, authenticated
  using ((is_active
          and shop_id in (select private.active_shop_ids())
          and exists (select 1 from public.products p
                       where p.id = product_id and p.status = 'active'))
         or shop_id in (select private.shops_where_role('staff')));
create policy "managers manage variants" on public.product_variants
  for all to authenticated
  using (shop_id in (select private.shops_where_role('manager')))
  with check (shop_id in (select private.shops_where_role('manager')));

-- product_images
create policy "images of active products are public" on public.product_images
  for select to anon, authenticated
  using ((shop_id in (select private.active_shop_ids())
          and exists (select 1 from public.products p where p.id = product_id and p.status = 'active'))
         or shop_id in (select private.shops_where_role('staff')));
create policy "managers manage images" on public.product_images
  for all to authenticated
  using (shop_id in (select private.shops_where_role('manager')))
  with check (shop_id in (select private.shops_where_role('manager')));

-- inventory_items (quantities are additionally guarded by trigger)
create policy "staff read inventory" on public.inventory_items
  for select to authenticated
  using (shop_id in (select private.shops_where_role('staff')));
create policy "managers edit inventory settings" on public.inventory_items
  for update to authenticated
  using (shop_id in (select private.shops_where_role('manager')))
  with check (shop_id in (select private.shops_where_role('manager')));

-- inventory_movements: staff read; managers may log manual movements directly.
-- Sales and reservations are written by Step 2 RPCs (SECURITY DEFINER).
create policy "staff read movements" on public.inventory_movements
  for select to authenticated
  using (shop_id in (select private.shops_where_role('staff')));
create policy "managers log manual movements" on public.inventory_movements
  for insert to authenticated
  with check (
    shop_id in (select private.shops_where_role('manager'))
    and reason in ('restock', 'return', 'damage', 'adjustment', 'stocktake')
    and actor_id = (select auth.uid()));

-- stock_reservations
create policy "staff read reservations" on public.stock_reservations
  for select to authenticated
  using (shop_id in (select private.shops_where_role('staff')));

-- orders (inserts come from Step 2 checkout / POS RPCs)
create policy "customers read own orders, staff read their shop's" on public.orders
  for select to authenticated
  using (customer_id = (select auth.uid())
         or shop_id in (select private.shops_where_role('staff')));
create policy "staff update their shop's orders" on public.orders
  for update to authenticated
  using (shop_id in (select private.shops_where_role('staff')))
  with check (shop_id in (select private.shops_where_role('staff')));

-- order_items
create policy "read items of visible orders" on public.order_items
  for select to authenticated
  using (shop_id in (select private.shops_where_role('staff'))
         or exists (select 1 from public.orders o
                     where o.id = order_id and o.customer_id = (select auth.uid())));

-- order_status_history
create policy "read history of visible orders" on public.order_status_history
  for select to authenticated
  using (shop_id in (select private.shops_where_role('staff'))
         or exists (select 1 from public.orders o
                     where o.id = order_id and o.customer_id = (select auth.uid())));

-- low_stock_alerts
create policy "staff read alerts" on public.low_stock_alerts
  for select to authenticated
  using (shop_id in (select private.shops_where_role('staff')));
create policy "staff acknowledge alerts" on public.low_stock_alerts
  for update to authenticated
  using (shop_id in (select private.shops_where_role('staff')))
  with check (shop_id in (select private.shops_where_role('staff')));

-- Views
revoke all on public.inventory_overview from anon;
grant select on public.inventory_overview to authenticated;
grant select on public.storefront_availability to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Realtime: the admin dashboard subscribes with a `shop_id=eq.<id>` filter
-- (RLS still applies, so a shop never receives another shop's events).
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.inventory_items, public.orders, public.low_stock_alerts, public.inventory_movements;
  end if;
end $$;
