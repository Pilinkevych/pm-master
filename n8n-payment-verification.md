# Verifying payments in `pm-master-payment`

The webhook URL sits in the HTML of every checkout form, and the workflow
currently believes whatever is POSTed to it. `Is Approved?` reads
`transactionStatus` straight out of the request body, so anyone can send

```bash
curl -X POST https://aikinomaker.app.n8n.cloud/webhook/pm-master-payment \
  -H 'Content-Type: application/json' \
  -d '{"orderReference":"pm_unlimited_1","transactionStatus":"Approved",
       "email":"attacker@example.com","amount":29,"currency":"USD"}'
```

and be given an Unlimited plan without paying. Checking the incoming signature
would help, but only while the secret stays private — and it has leaked once
already.

**Ask WayForPay instead.** A forger cannot invent a transaction inside
WayForPay's own records, so a lookup by `orderReference` settles it no matter
who knows the secret.

## The change

Insert two nodes between **Parse Body** and **Is Approved?**, then repoint
`Is Approved?` at the verified data.

```
Webhook → Parse Body → [Sign Status Query] → [Ask WayForPay] → Is Approved? → …
```

### 1. Code node — `Sign Status Query`

```js
const crypto = require('crypto');
const MERCHANT_SECRET = '<same new secret as Build WFP Response>';
const MERCHANT_ACCOUNT = 'pm_master_club';

const orderReference = $('Parse Body').item.json.orderReference;

// CHECK_STATUS signs only these two fields, in this order.
const signature = crypto
  .createHmac('md5', MERCHANT_SECRET)
  .update([MERCHANT_ACCOUNT, orderReference].join(';'))
  .digest('hex');

return [{ json: {
  apiVersion: 1,
  transactionType: 'CHECK_STATUS',
  merchantAccount: MERCHANT_ACCOUNT,
  orderReference,
  merchantSignature: signature,
} }];
```

### 2. HTTP Request node — `Ask WayForPay`

```
Method: POST
URL:    https://api.wayforpay.com/api
Body Content Type: JSON
Specify Body: Using JSON
JSON:   {{ JSON.stringify($json) }}
```

The reply carries the authoritative `transactionStatus`, `amount`, `currency`
and `email`.

### 3. Rewire `Is Approved?`

Point the condition at the reply, not at the request body:

```
{{ $json.transactionStatus === 'Approved' }}
```

### 4. Take the buyer from the order reference

This matters as much as the status check. `Get User ID` reads `email` from the
POSTed body, so a forger could quote someone else's real `orderReference` and
swap in their own address — buying nothing and receiving the plan.

CHECK_STATUS does not return the buyer's email, so it cannot settle this.
Instead `create-payment` now writes the buyer's id into the reference itself:

```
pm_<plan>_<userId>_<timestamp>
pm_team_<seats>_<userId>_<timestamp>
```

WayForPay echoes that reference back and CHECK_STATUS confirms it exists, so
the id is as trustworthy as the payment. A user id is a UUID and carries no
underscores, which keeps the split unambiguous.

**In `Parse Body`**, pull it out:

```js
const parts = String(orderReference).split('_');
const userId = parts[1] === 'team' ? parts[3] : parts[2];
```

**Then delete the `Get User ID` node entirely** — there is nothing left to look
up. Wire `Is Approved?` straight to `Insert Subscription`, and set its
`user_id` to:

```
{{ $('Parse Body').item.json.userId }}
```

Take `amount` and `currency` from `Ask WayForPay` as well, so the stored record
matches what was actually charged rather than what the caller claimed.

## What this leaves open, deliberately

The 1 UAH test payments from `__pmTestPay()` stay valid: WayForPay really does
have those transactions, and `create-payment` refuses test mode to anyone but
the admin, so nobody else can bring one into existence.

No amount check is needed on top: the price is chosen server-side in
`create-payment`, and the plan key is baked into the `orderReference` that
WayForPay itself confirms.

## Checking it worked

1. `__pmTestPay()` → the plan should still activate, now via the verified path.
2. Run the forged `curl` above with a made-up `orderReference`. WayForPay
   answers that no such order exists, `Is Approved?` goes false, and no
   subscription appears. That is the whole point of the change.

## One trap worth knowing

Answering WayForPay with `status: 'decline'` does not mean "we didn't like
this" — it tells them to **refund the payment**. Both response branches must
send `accept`, which only acknowledges receipt; whether the plan is granted is
our own business. Getting this wrong once cost several test payments: the
declined branch refunded them, CHECK_STATUS then reported `Refunded`, the
condition stayed false, and the loop fed itself.
