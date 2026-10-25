-- Demo-only setup for the in-browser playground (PGlite).
-- 1) Stand-ins for the parts of Supabase the schema expects (auth schema, API roles).
-- 2) After the real migration + seed run, demo people and a second shop.

-- @@ BEFORE_SCHEMA
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  end if;
end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- @@ AFTER_SEED
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'amara@corner.shop',  '{"full_name":"Amara (owner)"}'),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'jo@corner.shop',     '{"full_name":"Jo (cashier)"}'),
  ('aaaaaaaa-0000-4000-8000-000000000003', 'sam@example.com',    '{"full_name":"Sam (customer)"}'),
  ('aaaaaaaa-0000-4000-8000-000000000004', 'lee@othershop.com',  '{"full_name":"Lee (owner of another shop)"}');

insert into public.shop_members (shop_id, user_id, role) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000001', 'owner'),
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000002', 'staff');

insert into public.shops (id, name, slug) values
  ('99999999-9999-4999-8999-999999999999', 'Other Shop', 'other-shop');
insert into public.shop_members (shop_id, user_id, role) values
  ('99999999-9999-4999-8999-999999999999', 'aaaaaaaa-0000-4000-8000-000000000004', 'owner');
insert into public.products (id, shop_id, name, slug, status) values
  ('99999999-0000-4000-8000-000000000001', '99999999-9999-4999-8999-999999999999', 'Desk Lamp', 'desk-lamp', 'active');
insert into public.product_variants (id, shop_id, product_id, sku, price_cents) values
  ('99999999-0000-4000-8000-000000000002', '99999999-9999-4999-8999-999999999999',
   '99999999-0000-4000-8000-000000000001', 'LAMP-1', 2900);
insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, note) values
  ('99999999-9999-4999-8999-999999999999', '99999999-0000-4000-8000-000000000002', 'restock', 7, 'opening stock');
