const crypto = require('crypto');

const SUPA_URL   = process.env.SUPABASE_URL || 'https://ijfawcrcmmvjhilpytsg.supabase.co';
// Public key — it ships in every page anyway. Defaulted so a missing env var
// can't turn checkout into a silent 401 for everyone.
const SUPA_ANON  = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlqZmF3Y3JjbW12amhpbHB5dHNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI5MDY0NjQsImV4cCI6MjA5ODQ4MjQ2NH0.bcjSxVd5UNeaoM1yiK7NQoma2HEZepmTrDaz7A_p5CQ';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'ai.kinomaker@gmail.com';

const MERCHANT_LOGIN  = process.env.WAYFORPAY_MERCHANT || 'pm_master_club';
const MERCHANT_SECRET = process.env.WAYFORPAY_SECRET || '';
const DOMAIN = 'pm-master.club';

// Prices live here and nowhere else. The browser names a plan, never an amount —
// otherwise anyone can open devtools and buy Unlimited for a dollar.
const PLANS = {
  quiz_only: { amount: 5,  name: 'PM Master Quiz Only - PMP Trainer' },
  starter:   { amount: 9,  name: 'PM Master Starter - 3 projects' },
  pro:       { amount: 19, name: 'PM Master Pro - 10 projects' },
  unlimited: { amount: 29, name: 'PM Master Unlimited' },
};

function seatPrice(seats) {
  if (seats <= 10)  return 7;
  if (seats <= 50)  return 5;
  if (seats <= 200) return 3.5;
  return null;
}

async function getUser(authHeader) {
  const token = (authHeader || '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  const res = await fetch(`${SUPA_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SUPA_ANON },
  });
  if (!res.ok) return null;
  const user = await res.json();
  return user && user.email ? user : null;
}

// Resolve what the user asked for into an amount we decided on.
function resolveOrder(plan, seats) {
  if (plan === 'team') {
    const n = parseInt(seats, 10);
    if (!Number.isInteger(n) || n < 2 || n > 200) return { error: 'Team plan takes 2–200 seats' };
    const per = seatPrice(n);
    return {
      planKey: 'team_' + n,
      amount: Math.round(n * per),
      name: `PM Master Team - ${n} seats/month`,
    };
  }
  const p = PLANS[plan];
  if (!p) return { error: 'Unknown plan' };
  return { planKey: plan, amount: p.amount, name: p.name };
}

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: JSON.stringify({ error: 'Method Not Allowed' }) };
  }
  if (!MERCHANT_SECRET) {
    return { statusCode: 500, body: JSON.stringify({ error: 'WAYFORPAY_SECRET not set' }) };
  }

  const user = await getUser(event.headers.authorization || event.headers.Authorization);
  if (!user) {
    return { statusCode: 401, body: JSON.stringify({ error: 'Sign in first' }) };
  }

  let body;
  try { body = JSON.parse(event.body || '{}'); } catch {
    return { statusCode: 400, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  const order = resolveOrder(body.plan, body.seats);
  if (order.error) {
    return { statusCode: 400, body: JSON.stringify({ error: order.error }) };
  }

  let { amount, name } = order;
  let currency = 'USD';

  // Hidden 1 UAH rehearsal of the real flow: same plan key, same callbacks, so
  // n8n behaves exactly as in production — only the price is token. Admin only,
  // because otherwise this is a way to buy Unlimited for a hryvnia.
  if (body.test === true) {
    if (user.email.toLowerCase() !== ADMIN_EMAIL.toLowerCase()) {
      return { statusCode: 403, body: JSON.stringify({ error: 'Test payments are admin-only' }) };
    }
    amount = 1;
    currency = 'UAH';
    name = `[TEST] ${name}`;
  }

  const orderRef  = 'pm_' + order.planKey + '_' + Date.now();
  const orderDate = Math.floor(Date.now() / 1000);
  const amountStr = String(amount);

  // WayForPay signs a fixed field order; the posted values must match byte for byte.
  const sigData = [
    MERCHANT_LOGIN, DOMAIN, orderRef, orderDate,
    amountStr, currency, name, 1, amountStr,
  ].join(';');
  const signature = crypto.createHmac('md5', MERCHANT_SECRET).update(sigData, 'utf8').digest('hex');

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      action: 'https://secure.wayforpay.com/pay',
      fields: {
        merchantAccount:    MERCHANT_LOGIN,
        merchantDomainName: DOMAIN,
        orderReference:     orderRef,
        orderDate:          orderDate,
        amount:             amountStr,
        currency:           currency,
        orderLifetime:      86400,
        productName:        name,
        productCount:       1,
        productPrice:       amountStr,
        clientEmail:        user.email,
        language:           'EN',
        returnUrl:          'https://pm-master.club/.netlify/functions/payment-return',
        serviceUrl:         'https://aikinomaker.app.n8n.cloud/webhook/pm-master-payment',
        merchantSignature:  signature,
      },
    }),
  };
};
