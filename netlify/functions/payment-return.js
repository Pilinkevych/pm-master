// WayForPay POSTs the outcome here after the payment page closes. Treat it as a
// hint for what to show, not as proof: the authoritative record is the row n8n
// writes from the serviceUrl callback, which the page polls for.
const DECLINED = new Set([
  'Declined', 'Expired', 'Refunded', 'Voided', 'RefundInProcessing',
]);

function readBody(raw) {
  if (!raw) return {};
  // The body arrives form-encoded most of the time and as JSON some of the
  // time; which one is not worth guessing, so accept either.
  const trimmed = raw.trim();
  if (trimmed.startsWith('{')) {
    try { return JSON.parse(trimmed); } catch (e) { /* fall through */ }
  }
  const params = new URLSearchParams(raw);
  const out = {};
  for (const [k, v] of params) out[k] = v;
  // A JSON payload posted without a content type lands here as a single key.
  if (Object.keys(out).length === 1) {
    const only = Object.keys(out)[0];
    if (only.trim().startsWith('{')) {
      try { return JSON.parse(only); } catch (e) { /* keep what we have */ }
    }
  }
  return out;
}

exports.handler = async (event) => {
  let plan = '';
  let seats = '1';
  let status = '';
  let reason = '';

  try {
    const body = readBody(event.body);
    status = body.transactionStatus || '';
    reason = body.reason || '';

    // orderRef format: pm_starter_1234567890 or pm_team_5_1234567890
    const parts = String(body.orderReference || '').split('_');
    if (parts.length >= 3) {
      if (parts[1] === 'team') {
        plan = 'team_' + parts[2];
        seats = parts[2];
      } else {
        plan = parts[1];
      }
    }
  } catch (e) {}

  // Only an explicit refusal counts as failure. A missing or unfamiliar status
  // means "ask the database" — better a moment of waiting than telling someone
  // their successful payment failed.
  const location = DECLINED.has(status)
    ? `/?payment=failed&reason=${encodeURIComponent(reason || status)}`
    : `/?payment=success&plan=${encodeURIComponent(plan)}&seats=${encodeURIComponent(seats)}`;

  return { statusCode: 302, headers: { Location: location }, body: '' };
};
