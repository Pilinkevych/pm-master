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

### 4. Take the buyer from the reply too

This is the part that matters as much as the status check. `Get User ID`
currently reads `email` from the POSTed body, so a forger could quote someone
else's real `orderReference` and swap in their own address. Use WayForPay's
copy instead:

```
p_email: {{ $('Ask WayForPay').item.json.email }}
```

And in `Insert Subscription`, take `amount` and `currency` from `Ask WayForPay`
as well, so the stored record matches what was actually charged.

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
