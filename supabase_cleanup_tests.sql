-- Clearing out the 1 UAH rehearsals before real customers arrive.
-- Look first, delete second — this table is what says who has paid.

-- ── LOOK ─────────────────────────────────────────────────────────────────────
select id, user_id, plan, status, amount, currency, expires_at,
       order_reference, created_at
  from subscriptions
 order by created_at desc;

-- Test runs are the ones charged 1 UAH. Real purchases are in USD, so currency
-- alone separates them — but read the list above before trusting that.
-- select count(*) from subscriptions where currency = 'UAH' and amount = 1;

-- ── DELETE ───────────────────────────────────────────────────────────────────
-- delete from subscriptions where currency = 'UAH' and amount = 1;

-- The retry loop may have inserted the same order more than once while the
-- response signature was stale. Keeps the earliest row of each order:
-- delete from subscriptions a using subscriptions b
--  where a.order_reference = b.order_reference
--    and a.created_at > b.created_at;

-- ── AFTERWARDS ───────────────────────────────────────────────────────────────
-- The test account goes through the dashboard, not SQL:
--   Authentication → Users → ai.kinomaker+test2@gmail.com → Delete user
-- Deleting the auth row cascades to their projects; deleting a subscriptions
-- row does not touch the account.
