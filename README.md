# Stock

E-commerce storefront + real-time inventory and POS for local retail shops, built on
Next.js (App Router), Tailwind, Supabase and Vercel. One deployment serves many shops.

**Status:** Step 1 (database schema) is done. Next up: Step 2 (checkout, POS sale and
reservation functions), Step 3 (UI flows), Step 4 (MVP roadmap).

## Try it

`demo/` is a playground that runs this exact migration in the browser (via PGlite, Postgres compiled to WebAssembly). Open `demo/index.html` through any static server, or use the Vercel deployment. Reload to reset.

## What's here

```
supabase/
  migrations/20261025120000_initial_schema.sql   tables, enums, triggers, access rules (RLS)
  seed.sql                                        one demo shop with products and stock
  tests/smoke_test.sql                            27 checks; runs in a transaction and rolls back
demo/
  index.html                                      in-browser playground (restock, POS, online orders, stress tests)
  demo-setup.sql                                  Supabase stand-ins + demo people for the playground
docs/how-it-works.mp4                             short explainer video
```

## Run it

**Option A: Supabase dashboard (no tools needed)**

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor**, paste `supabase/migrations/20261025120000_initial_schema.sql`, and run it.
3. Paste `supabase/tests/smoke_test.sql` and run it. Every row should show `pass = true`
   and `total_failed = 0`. It cleans up after itself.
4. Optional: run `supabase/seed.sql` for demo data.

**Option B: Supabase CLI (local, needs Docker)**

```bash
supabase init            # once; keep the existing supabase/ folder
supabase start
supabase db reset        # applies the migration + seed
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/smoke_test.sql
```

To push to a hosted project: `supabase link --project-ref <ref>` then `supabase db push`.

**Make yourself the platform admin** (after signing up through your app or the Auth page):

```sql
update public.profiles set is_platform_admin = true where email = 'you@example.com';
```

## How the data model works

- **Shops** are the top level. Every product, order, stock row and log entry carries a
  `shop_id`, and foreign keys include it, so data can't leak or be linked across shops.
- **People.** Each login has one `profiles` row. Staff access is per shop in `shop_members`
  (`staff` < `manager` < `owner`). Customers can buy from any shop. Platform admins
  (the managed-service team) act as owner everywhere.
- **Catalog.** `categories` → `products` → `product_variants`. Price, SKU and barcode live
  on the variant; a simple product has one "Default" variant.
- **Stock.** `inventory_items` holds `on_hand`, `reserved` and `available`
  (on_hand minus reserved) per variant. Counts change **only** by inserting into
  `inventory_movements`, an append-only ledger. A trigger applies each movement under a
  row lock, and database checks reject overselling.

  | Movement | on_hand | reserved | When |
  | --- | --- | --- | --- |
  | `restock`, `return` | + | | Goods in |
  | `reservation` | | + | Online checkout holds stock |
  | `sale_online` | − | − | Payment confirmed |
  | `reservation_release` | | − | Order cancelled / hold expired |
  | `sale_pos` | − | | In-store quick deduct |
  | `damage`, `adjustment`, `stocktake` | ± | | Corrections |

- **Orders.** Online or POS, with per-shop numbers from #1001, price snapshots on each
  line, totals in cents, validated status changes and a status timeline. Guests track an
  order with `track_order(order_number, tracking_token)`.
- **Low-stock alerts** open and close automatically. `inventory_items`, `orders`,
  `low_stock_alerts` and `inventory_movements` are published to Supabase Realtime.

## Access summary

| Who | Can |
| --- | --- |
| Shopper (anon) | Browse active shops' catalog, see in-stock / "only N left", track an order |
| Customer | + read own profile and own orders |
| Staff | + read all of their shop's data, update orders, acknowledge alerts |
| Manager | + edit catalog and stock settings, log restocks and corrections |
| Owner | + shop settings and team |
| Platform admin | Owner in every shop |
