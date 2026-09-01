# Fygaro Shopify Middleware

Custom Shopify app proxy middleware that powers a hosted Fygaro checkout. It
quotes cart totals/shipping via the Shopify Storefront API, snaps the checkout
into `fygaro_checkouts`, redirects the buyer to a Fygaro Link, and — when the
Fygaro payment hook fires — creates the Shopify order via the Admin GraphQL API.

## Setup

Copy the environment template and fill in your values. Real secrets are never
committed — `.env.development` and `.env.production` are gitignored (see
`.gitignore`), and `.env.example` only holds placeholders.

```sh
cp .env.example .env.development   # local development
# or, for a production deploy:
cp .env.example .env.production
```

Then install dependencies and boot the app:

```sh
bin/setup          # or: bundle install && bin/rails db:prepare
bin/dev            # dev server (Puma + JS bundling)
```

`HOST` must be a public URL reachable by both Shopify webhooks and the Fygaro
Hook URL (use a tunnel in development, e.g. `https://your-tunnel.example.com`).

## Environment variables

All values are loaded from `.env.development` / `.env.production` via
`dotenv-rails`. `.env.example` is the single source of placeholder keys.

| Variable | Required | Where used | Notes |
| --- | --- | --- | --- |
| `SHOPIFY_API_KEY` | yes | Shopify app auth | Partners dashboard app key |
| `SHOPIFY_API_SECRET` | yes | Shopify app auth + proxy/HMAC signing | Partners dashboard app secret |
| `HOST` | yes | Shopify `Context.setup` | Public URL of the app |
| `FYGARO_API_KEY` | yes | JWT `kid` + inbound hook `Fygaro-Key-ID` | Fygaro API key |
| `FYGARO_API_SECRET` | yes | JWT HMAC sign + hook `v1` verify | Fygaro API secret |
| `FYGARO_PAYMENT_LINK_URL` | yes | hosted checkout redirect | e.g. `https://www.fygaro.com/en/pb/<link-uuid>/` |
| `FIGARO_WEBHOOK_SECRET` | no | hook verify alias | Same value as `FYGARO_API_SECRET` |
| `FYGARO_WEBHOOK_SECRET` | no | hook verify alias (canonical) | Same value as `FYGARO_API_SECRET` |
| `FYGARO_IDR_TO_USD_RATE` | no | `Fygaro::Fx` fallback FX rate | Default `16000`; used only when ECB cache is unavailable |

Both `FIGARO_WEBHOOK_SECRET` and `FYGARO_WEBHOOK_SECRET` are accepted spellings
for the same value and should be set equal to `FYGARO_API_SECRET`.

## Fygaro Hook URL

Fygaro notifies this app after a successful payment. In the Fygaro dashboard,
set the Link's **Hook URL** to:

```
https://<HOST>/api/fygaro/hooks
```

The hook verifies `Fygaro-Signature` (HMAC-SHA256), marks the matching
`FygaroCheckout` as paid, and enqueues `FygaroCreateOrderJob`, which creates
the Shopify order via the Admin `orderCreate` mutation with a `CUSTOM` payment
referencing the Fygaro transaction.

## Create a payment Link

Dashboard > Fygaro Links > Create. Choose **Variable Amount**, with **require
jwt is checked**.

1. **Dashboard → Fygaro Links → Create.**
2. Amount type → **Variable Amount** — required, because a fixed-amount Link
   cannot accept the checkout amount/currency from the JWT this middleware
   mints (`app/services/fygaro/gateway.rb`).
3. Check **Require JWT** so the Link validates the signed amount/currency
   before showing the checkout. Do not leave it unchecked.
4. Save/publish, copy the **Link URL** (e.g.
   `https://www.fygaro.com/en/pb/<uuid>/`) and set it as
   `FYGARO_PAYMENT_LINK_URL` in `.env.development` / `.env.production` (see
   Environment variables).
5. On the same Link, set the **Hook URL** to `https://<HOST>/api/fygaro/hooks`
   and make sure `FIGARO_WEBHOOK_SECRET` / `FYGARO_WEBHOOK_SECRET` equal
   `FYGARO_API_SECRET`.

The IDR→USD conversion (`Fygaro::Fx`, with the offline
`FYGARO_IDR_TO_USD_RATE` fallback) happens server-side, so buyers are charged
the USD equivalent of the cart while the Shopify order itself is created in the
store's native currency (e.g. IDR).

## Ruby version

Stated in `.ruby-version`. Developed against Ruby 3.4.x.

## System dependencies

* Ruby (see `.ruby-version`)
* PostgreSQL
* Node.js + Bun (JS bundling via `jsbundling-rails`)
* Shopify CLI (for app auth/tunneling)

## Database creation

```sh
bin/rails db:create
bin/rails db:migrate
```

The middleware uses a single `fygaro_checkouts` table (plus the stock Shopify
app tables). Shopify orders are created via the Admin API; the local `orders`
table is populated by the `orders/create` webhook.

## How to run the test suite

```sh
bin/rails test
bundle exec rubocop
```

## Services

* **Solid Queue** (Active Job) — processes `FygaroCreateOrderJob`,
  `FygaroRefreshFxJob`, and webhook jobs.
* **`Fygaro::Fx` / `eu_central_bank`** — IDR→USD conversion for the Fygaro
  checkout amount, with an offline fallback from `FYGARO_IDR_TO_USD_RATE`.
