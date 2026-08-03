const SUPA_URL = process.env.SUPABASE_URL || 'https://ijfawcrcmmvjhilpytsg.supabase.co';
const SUPA_ANON = process.env.SUPABASE_ANON_KEY || '';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'ai.kinomaker@gmail.com';

// Without this the endpoint is an open spam relay: anyone could POST here and
// send mail through our Brevo account. Ask Supabase who the token belongs to —
// cheaper than a JWT lib, and it also catches revoked/expired sessions.
async function verifyAdmin(authHeader) {
  const token = (authHeader || '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return { ok: false, status: 401, error: 'Missing bearer token' };

  const res = await fetch(`${SUPA_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: SUPA_ANON },
  });
  if (!res.ok) return { ok: false, status: 401, error: 'Invalid session' };

  const user = await res.json();
  if (!user.email || user.email.toLowerCase() !== ADMIN_EMAIL.toLowerCase()) {
    return { ok: false, status: 403, error: 'Not an admin' };
  }
  return { ok: true };
}

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  const BREVO_KEY = process.env.BREVO_API_KEY;
  if (!BREVO_KEY) {
    return { statusCode: 500, body: JSON.stringify({ error: 'BREVO_API_KEY not set' }) };
  }

  const auth = await verifyAdmin(event.headers.authorization || event.headers.Authorization);
  if (!auth.ok) {
    return { statusCode: auth.status, body: JSON.stringify({ error: auth.error }) };
  }

  let body;
  try { body = JSON.parse(event.body); } catch {
    return { statusCode: 400, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  const { to, subject, htmlContent } = body;
  if (!to || !subject || !htmlContent) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Missing fields' }) };
  }

  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'api-key': BREVO_KEY },
    body: JSON.stringify({
      sender: { name: 'PM Master', email: 'noreply@pm-master.club' },
      replyTo: { name: 'Yuriy from PM Master', email: 'yuriy.pilinkevych@gmail.com' },
      to: [{ email: to }],
      subject,
      htmlContent
    })
  });

  const text = await res.text();
  return {
    statusCode: res.ok ? 200 : res.status,
    headers: { 'Content-Type': 'application/json' },
    body: res.ok ? JSON.stringify({ ok: true }) : JSON.stringify({ error: text })
  };
};
