const crypto = require('crypto');

const MERCHANT_ACCOUNT = process.env.WAYFORPAY_MERCHANT || 'pm_master_club';
const MERCHANT_SECRET  = process.env.WAYFORPAY_SECRET || '';

// WayForPay POSTs here after the payment page closes, but the body is not
// dependable — a refusal often arrives with no transactionStatus at all, which
// made every decline look like a success. So we ask them directly instead.
function readBody(raw) {
  if (!raw) return {};
  const trimmed = raw.trim();
  if (trimmed.startsWith('{')) {
    try { return JSON.parse(trimmed); } catch (e) { /* fall through */ }
  }
  const out = {};
  for (const [k, v] of new URLSearchParams(raw)) out[k] = v;
  // A JSON payload posted without a content type lands here as a single key.
  if (Object.keys(out).length === 1) {
    const only = Object.keys(out)[0];
    if (only.trim().startsWith('{')) {
      try { return JSON.parse(only); } catch (e) { /* keep what we have */ }
    }
  }
  return out;
}

async function checkStatus(orderReference) {
  if (!MERCHANT_SECRET || !orderReference) return null;
  // CHECK_STATUS signs these two fields only, in this order.
  const signature = crypto
    .createHmac('md5', MERCHANT_SECRET)
    .update([MERCHANT_ACCOUNT, orderReference].join(';'))
    .digest('hex');

  try {
    const res = await fetch('https://api.wayforpay.com/api', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        apiVersion: 1,
        transactionType: 'CHECK_STATUS',
        merchantAccount: MERCHANT_ACCOUNT,
        orderReference,
        merchantSignature: signature,
      }),
    });
    return await res.json();
  } catch (e) {
    return null;
  }
}

exports.handler = async (event) => {
  const body = readBody(event.body);
  const orderReference = String(body.orderReference || '');

  let plan = '';
  let seats = '1';

  // pm_<plan>_<userId>_<ts>, or pm_team_<seats>_<userId>_<ts>. Counting from
  // the end keeps quiz_only — the one plan key with an underscore in it —
  // from shifting every field along by one.
  const parts = orderReference.split('_');
  if (parts.length >= 4 && parts[0] === 'pm') {
    const mid = parts.slice(1, parts.length - 2);
    if (mid[0] === 'team') {
      plan = 'team_' + mid[1];
      seats = mid[1];
    } else {
      plan = mid.join('_');
    }
  }

  const status = await checkStatus(orderReference);
  const wfpStatus = status && status.transactionStatus;

  // Approved and InProcessing are on their way to becoming a subscription, and
  // the page polls for the row. Anything else WayForPay names — Declined,
  // Refunded, Expired — is told to the buyer as it is. When the lookup itself
  // fails we fall through to polling rather than guess either way.
  const refused = wfpStatus && wfpStatus !== 'Approved' && wfpStatus !== 'InProcessing' && wfpStatus !== 'Pending';

  const location = refused
    ? `/?payment=failed&reason=${encodeURIComponent(status.reason || wfpStatus)}`
    : `/?payment=success&plan=${encodeURIComponent(plan)}&seats=${encodeURIComponent(seats)}`;

  return { statusCode: 302, headers: { Location: location }, body: '' };
};
