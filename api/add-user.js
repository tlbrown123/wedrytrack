// Lets an active admin add a new user from inside the app (account chip > Manage users > Add user),
// so nobody needs the Supabase dashboard for it.
//
// Needs one Vercel environment variable: SUPABASE_SECRET_KEY (Supabase > Project Settings > API Keys,
// the secret key, or the legacy service_role key). It never reaches the browser.
//
// Flow: check the caller is an active admin (using their own sign-in), create the account already
// confirmed with the password the admin chose, then set name, role and Active using the caller's
// sign-in so the database's own admin rules still apply.

const SUPABASE_URL = process.env.SUPABASE_URL || "https://ultutndmuzdvtphrxgbo.supabase.co";
const PUBLISHABLE_KEY = process.env.SUPABASE_PUBLISHABLE_KEY || "sb_publishable_qEX-utrIl8bYSh52Q6t14A_pjOfEZXG";
const SECRET_KEY = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || "";

function send(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

async function readBody(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") return JSON.parse(req.body || "{}");
  let raw = "";
  for await (const chunk of req) raw += chunk;
  return JSON.parse(raw || "{}");
}

async function asCaller(token, path, init = {}) {
  return fetch(SUPABASE_URL + path, {
    ...init,
    headers: { apikey: PUBLISHABLE_KEY, Authorization: "Bearer " + token, "Content-Type": "application/json", ...(init.headers || {}) },
  });
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST" });
  if (!SECRET_KEY) return send(res, 500, { error: "Adding users is not set up yet. The SUPABASE_SECRET_KEY setting is missing in Vercel." });

  const token = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!token) return send(res, 401, { error: "Please sign in again" });

  let body;
  try { body = await readBody(req); } catch (e) { return send(res, 400, { error: "Bad request" }); }
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");
  const name = String(body.name || "").trim();
  const role = body.role === "admin" ? "admin" : "tech";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return send(res, 400, { error: "Enter a valid email" });
  if (password.length < 8) return send(res, 400, { error: "Starting password must be at least 8 characters" });

  // 1. Is the caller an active admin? This also rejects an expired or fake sign-in.
  const chk = await asCaller(token, "/rest/v1/rpc/is_admin", { method: "POST", body: "{}" });
  if (chk.status === 401) return send(res, 401, { error: "Please sign in again" });
  if (!chk.ok || (await chk.json()) !== true) return send(res, 403, { error: "Only an admin can add users" });

  // 2. Create the account, already confirmed, so they can sign in right away.
  const cr = await fetch(SUPABASE_URL + "/auth/v1/admin/users", {
    method: "POST",
    headers: { apikey: SECRET_KEY, Authorization: "Bearer " + SECRET_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { name } }),
  });
  const created = await cr.json().catch(() => ({}));
  if (!cr.ok) {
    const msg = String(created.msg || created.message || created.error_description || created.error || "");
    if (cr.status === 422 && /already|exists|registered/i.test(msg + " " + (created.error_code || "")))
      return send(res, 409, { error: "That email already has an account. Find it in the list and tick Active." });
    if (cr.status === 401 || cr.status === 403)
      return send(res, 500, { error: "The SUPABASE_SECRET_KEY setting in Vercel is not right. Check it was copied in full." });
    return send(res, 502, { error: msg || "Could not create the account" });
  }
  const id = created.id || (created.user && created.user.id);

  // 3. Turn them on with their name and role (as the admin, so the database's rules apply).
  const up = await asCaller(token, "/rest/v1/profiles?id=eq." + encodeURIComponent(id), {
    method: "PATCH",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ name: name || email.split("@")[0], role, active: true }),
  });
  const rows = await up.json().catch(() => []);
  if (!up.ok || !Array.isArray(rows) || !rows.length)
    return send(res, 200, { id, email, warning: "Account created, but could not turn it on. Tick Active for them in the list and Save." });

  return send(res, 200, { id, email, name: rows[0].name, role: rows[0].role, active: rows[0].active });
};
