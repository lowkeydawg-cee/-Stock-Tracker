-- =============================================================================
-- Smoke test for the Step 1 schema.
-- Paste into the Supabase SQL editor (or `psql -f`) after running the migration.
-- Everything runs inside a transaction and is rolled back, so it leaves no data.
-- Result: one row per check with pass = true/false.
-- =============================================================================
begin;

create temp table results (n serial, check_name text, pass boolean);
grant all on results to public;
grant all on sequence results_n_seq to public;

create function pg_temp.check(name text, ok boolean) returns void language sql as $$
  insert into results (check_name, pass) values (name, coalesce(ok, false));
$$;

-- Runs q and records a pass only if it raises an error.
create function pg_temp.expect_error(name text, q text) returns void language plpgsql as $$
begin
  begin
    execute q;
    insert into results (check_name, pass) values (name, false);
  exception when others then
    insert into results (check_name, pass) values (name || '  [' || sqlerrm || ']', true);
  end;
end $$;

create function pg_temp.act_as(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
$$;

-- ---------------------------------------------------------------- test data
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000a1', 'owner-a@test.local'),
  ('00000000-0000-4000-8000-0000000000a2', 'staff-a@test.local'),
  ('00000000-0000-4000-8000-0000000000b1', 'owner-b@test.local'),
  ('00000000-0000-4000-8000-0000000000c1', 'customer@test.local');

insert into public.shops (id, name, slug) values
  ('00000000-0000-4000-8000-00000000aaaa', 'Test Shop A', 'test-shop-a'),
  ('00000000-0000-4000-8000-00000000bbbb', 'Test Shop B', 'test-shop-b');
insert into public.shop_members (shop_id, user_id, role) values
  ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000a1', 'owner'),
  ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000a2', 'staff'),
  ('00000000-0000-4000-8000-00000000bbbb', '00000000-0000-4000-8000-0000000000b1', 'owner');

select pg_temp.check('profile auto-created for new users',
  (select count(*) = 4 from public.profiles where email like '%@test.local'));

insert into public.products (id, shop_id, name, slug, status) values
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-00000000aaaa', 'T-shirt', 't-shirt', 'active');
insert into public.product_variants (id, shop_id, product_id, sku, name, price_cents) values
  ('00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-00000000aaaa',
   '00000000-0000-4000-8000-0000000000f1', 'TS-M', 'Medium', 1500);

select pg_temp.check('inventory row auto-created at zero',
  (select on_hand = 0 and reserved = 0 from public.inventory_items
    where variant_id = '00000000-0000-4000-8000-0000000000e1'));

-- ---------------------------------------------------------------- stock ledger
insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, note)
values ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'restock', 10, 'delivery');

select pg_temp.check('restock of 10 applied through the ledger',
  (select on_hand = 10 from public.inventory_items where variant_id = '00000000-0000-4000-8000-0000000000e1'));

select pg_temp.expect_error('direct edit of stock is blocked',
  $q$ update public.inventory_items set on_hand = 999
       where variant_id = '00000000-0000-4000-8000-0000000000e1' $q$);

select pg_temp.expect_error('ledger rows cannot be edited',
  $q$ update public.inventory_movements set note = 'tampered' $q$);

-- Online order reserves 6
insert into public.orders (id, shop_id, channel, fulfillment_method, customer_id, customer_email) values
  ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-00000000aaaa', 'online', 'pickup',
   '00000000-0000-4000-8000-0000000000c1', 'customer@test.local');
insert into public.order_items (order_id, variant_id, quantity) values
  ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000e1', 6);
insert into public.inventory_movements (shop_id, variant_id, reason, reserved_delta, order_id) values
  ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'reservation', 6,
   '00000000-0000-4000-8000-0000000000d1');

select pg_temp.check('order subtotal computed from items (6 x 15.00)',
  (select subtotal_cents = 9000 and total_cents = 9000 from public.orders where id = '00000000-0000-4000-8000-0000000000d1'));
select pg_temp.check('first order in shop is #1001',
  (select order_number = 1001 from public.orders where id = '00000000-0000-4000-8000-0000000000d1'));
select pg_temp.check('reservation leaves 4 available',
  (select available = 4 from public.inventory_items where variant_id = '00000000-0000-4000-8000-0000000000e1'));
select pg_temp.check('low-stock alert opened (4 <= threshold 5)',
  (select count(*) = 1 from public.low_stock_alerts
    where variant_id = '00000000-0000-4000-8000-0000000000e1' and status = 'open'));

-- POS sale cannot eat reserved stock
insert into public.orders (id, shop_id, channel, fulfillment_method, status) values
  ('00000000-0000-4000-8000-0000000000d2', '00000000-0000-4000-8000-00000000aaaa', 'pos', 'in_store', 'completed');
select pg_temp.expect_error('POS sale of 5 blocked (only 4 free)',
  $q$ insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, order_id)
      values ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'sale_pos', -5,
              '00000000-0000-4000-8000-0000000000d2') $q$);

insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, order_id, idempotency_key)
values ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'sale_pos', -2,
        '00000000-0000-4000-8000-0000000000d2', 'pos-tap-1');
select pg_temp.expect_error('retried POS tap with same key is rejected',
  $q$ insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, order_id, idempotency_key)
      values ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'sale_pos', -1,
              '00000000-0000-4000-8000-0000000000d2', 'pos-tap-1') $q$);

-- Payment confirmed: reserved stock becomes a sale
insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, reserved_delta, order_id) values
  ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'sale_online', -6, -6,
   '00000000-0000-4000-8000-0000000000d1');
select pg_temp.check('after POS 2 + online 6: on_hand 2, reserved 0',
  (select on_hand = 2 and reserved = 0 from public.inventory_items where variant_id = '00000000-0000-4000-8000-0000000000e1'));

-- ---------------------------------------------------------------- order status
select pg_temp.expect_error('pending -> shipped is not allowed',
  $q$ update public.orders set status = 'shipped' where id = '00000000-0000-4000-8000-0000000000d1' $q$);
update public.orders set status = 'confirmed', payment_status = 'paid' where id = '00000000-0000-4000-8000-0000000000d1';
update public.orders set status = 'ready_for_pickup' where id = '00000000-0000-4000-8000-0000000000d1';
select pg_temp.check('status timeline recorded (pending, confirmed, ready_for_pickup)',
  (select count(*) = 3 from public.order_status_history where order_id = '00000000-0000-4000-8000-0000000000d1'));
select pg_temp.check('guest tracking works with the right token',
  (select public.track_order(order_number, tracking_token) ->> 'status' = 'ready_for_pickup'
     from public.orders where id = '00000000-0000-4000-8000-0000000000d1'));
select pg_temp.check('guest tracking returns nothing with a wrong token',
  public.track_order(1001, gen_random_uuid()) is null);

-- ---------------------------------------------------------------- access rules
set local role authenticated;

select pg_temp.act_as('00000000-0000-4000-8000-0000000000b1');
select pg_temp.check('owner of shop B cannot see shop A orders',
  (select count(*) = 0 from public.orders where shop_id = '00000000-0000-4000-8000-00000000aaaa'));
select pg_temp.check('owner of shop B cannot see shop A stock',
  (select count(*) = 0 from public.inventory_items where shop_id = '00000000-0000-4000-8000-00000000aaaa'));
select pg_temp.expect_error('owner of shop B cannot add products to shop A',
  $q$ insert into public.products (shop_id, name, slug)
      values ('00000000-0000-4000-8000-00000000aaaa', 'Hack', 'hack') $q$);

select pg_temp.act_as('00000000-0000-4000-8000-0000000000a2');
select pg_temp.check('staff of shop A sees its stock and orders',
  (select count(*) = 1 from public.inventory_items) and (select count(*) = 2 from public.orders));
select pg_temp.expect_error('staff cannot log a manual restock (manager+ only)',
  $q$ insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta)
      values ('00000000-0000-4000-8000-00000000aaaa', '00000000-0000-4000-8000-0000000000e1', 'restock', 1) $q$);

select pg_temp.act_as('00000000-0000-4000-8000-0000000000c1');
select pg_temp.check('customer sees only own order',
  (select count(*) = 1 from public.orders));
select pg_temp.check('customer cannot read stock counts',
  (select count(*) = 0 from public.inventory_items));
select pg_temp.expect_error('customer cannot make self platform admin',
  $q$ update public.profiles set is_platform_admin = true where id = auth.uid() $q$);

select pg_temp.act_as('00000000-0000-4000-8000-0000000000a1');
select pg_temp.expect_error('last owner cannot leave the shop',
  $q$ delete from public.shop_members
       where shop_id = '00000000-0000-4000-8000-00000000aaaa' and user_id = auth.uid() $q$);

reset role;
set local role anon;
select pg_temp.act_as(null);
select pg_temp.check('shoppers see active products',
  (select count(*) >= 1 from public.products where shop_id = '00000000-0000-4000-8000-00000000aaaa'));
select pg_temp.check('shoppers see availability but not counts',
  (select in_stock from public.storefront_availability where variant_id = '00000000-0000-4000-8000-0000000000e1')
  and (select count(*) = 0 from public.inventory_items));
reset role;

-- ---------------------------------------------------------------- report
select n, check_name, pass,
       count(*) filter (where not pass) over () as total_failed
  from results order by n;

rollback;
