-- Demo data for local development (`supabase db reset` runs this automatically).
-- Creates one shop with a small catalog and opening stock. To manage it from the
-- dashboard, sign up and then run:
--   insert into public.shop_members (shop_id, user_id, role)
--   select '11111111-1111-4111-8111-111111111111', id, 'owner' from public.profiles where email = 'you@example.com';

insert into public.shops (id, name, slug, currency) values
  ('11111111-1111-4111-8111-111111111111', 'Demo Corner Shop', 'demo-corner-shop', 'USD');

insert into public.categories (id, shop_id, name, slug, sort_order) values
  ('22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-111111111111', 'Clothing', 'clothing', 1),
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-111111111111', 'Drinks',   'drinks',   2);

insert into public.products (id, shop_id, category_id, name, slug, description, status, is_featured) values
  ('33333333-3333-4333-8333-000000000001', '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-000000000001',
   'Classic T-shirt', 'classic-t-shirt', '100% cotton, everyday fit.', 'active', true),
  ('33333333-3333-4333-8333-000000000002', '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-000000000002',
   'Cold Brew Coffee 330ml', 'cold-brew-330', 'Ready to drink.', 'active', false);

insert into public.product_variants (id, shop_id, product_id, sku, barcode, name, options, price_cents, sort_order) values
  ('44444444-4444-4444-8444-000000000001', '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-000000000001',
   'TEE-S', '600000000001', 'Small',  '{"size":"S"}', 1500, 1),
  ('44444444-4444-4444-8444-000000000002', '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-000000000001',
   'TEE-M', '600000000002', 'Medium', '{"size":"M"}', 1500, 2),
  ('44444444-4444-4444-8444-000000000003', '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-000000000001',
   'TEE-L', '600000000003', 'Large',  '{"size":"L"}', 1500, 3),
  ('44444444-4444-4444-8444-000000000004', '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-000000000002',
   'CB-330', '600000000004', 'Default', '{}', 350, 1);

-- Opening stock goes through the ledger like every other change.
insert into public.inventory_movements (shop_id, variant_id, reason, on_hand_delta, note) values
  ('11111111-1111-4111-8111-111111111111', '44444444-4444-4444-8444-000000000001', 'stocktake', 12, 'opening count'),
  ('11111111-1111-4111-8111-111111111111', '44444444-4444-4444-8444-000000000002', 'stocktake', 20, 'opening count'),
  ('11111111-1111-4111-8111-111111111111', '44444444-4444-4444-8444-000000000003', 'stocktake', 4,  'opening count'),
  ('11111111-1111-4111-8111-111111111111', '44444444-4444-4444-8444-000000000004', 'stocktake', 48, 'opening count');
