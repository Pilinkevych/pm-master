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

    // pm_<plan>_<userId>_<ts>, or pm_team_<seats>_<userId>_<ts>. Counting from
    // the end keeps quiz_only — the one plan key with an underscore in it —
    // from shifting every field along by one.
    const parts = String(body.orderReference || '').split('_');
    if (parts.length >= 4 && parts[0] === 'pm') {
      const mid = parts.slice(1, parts.length - 2);
      if (mid[0] === 'team') {
        plan = 'team_' + mid[1];
        seats = mid[1];
      } else {
        plan = mid.join('_');
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
