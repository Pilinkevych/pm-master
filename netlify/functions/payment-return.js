exports.handler = async (event) => {
  // WayForPay POSTs the outcome here after the payment page closes — success
  // and failure alike. Read what actually happened before deciding where to go.
  let plan = '';
  let seats = '1';
  let status = '';
  let reason = '';

  try {
    const params = new URLSearchParams(event.body || '');
    const orderRef = params.get('orderReference') || '';
    status = params.get('transactionStatus') || '';
    reason = params.get('reason') || '';

    // orderRef format: pm_starter_1234567890 or pm_team_5_1234567890
    const parts = orderRef.split('_');
    if (parts.length >= 3) {
      if (parts[1] === 'team') {
        plan = 'team_' + parts[2];
        seats = parts[2];
      } else {
        plan = parts[1];
      }
    }
  } catch (e) {}

  // Approved and InProcessing both mean the money is on its way, and the page
  // already polls for the subscription. Anything else has to say so — telling
  // someone "Payment Accepted!" when the bank refused them is worse than
  // telling them nothing.
  const ok = status === 'Approved' || status === 'InProcessing' || status === 'Pending';

  const location = ok
    ? `/?payment=success&plan=${encodeURIComponent(plan)}&seats=${encodeURIComponent(seats)}`
    : `/?payment=failed&reason=${encodeURIComponent(reason || status || 'unknown')}`;

  return { statusCode: 302, headers: { Location: location }, body: '' };
};
