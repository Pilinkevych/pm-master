exports.handler = async (event) => {
  // WayForPay POSTs form data here after payment
  // Parse orderReference to extract plan key (format: pm_{planKey}_{timestamp})
  let plan = '';
  let seats = '1';

  try {
    const body = event.body || '';
    const params = new URLSearchParams(body);
    const orderRef = params.get('orderReference') || '';
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

  return {
    statusCode: 302,
    headers: {
      Location: '/?payment=success&plan=' + plan + '&seats=' + seats,
    },
    body: '',
  };
};
