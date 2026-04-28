/**
 * MediaDash APNs Relay Worker
 *
 * Two endpoints:
 *   POST /register  — MediaDash registers its APNs device token on launch
 *   POST /webhook   — Airtable automation fires when a new docket record is created
 *
 * Required Worker environment variables (set in Cloudflare dashboard):
 *   SHARED_SECRET      — arbitrary string; sent in X-MediaDash-Secret header by both
 *                        the app and Airtable automation
 *   APNS_PRIVATE_KEY   — full content of the .p8 file from Apple (including BEGIN/END lines)
 *   APNS_KEY_ID        — 10-char key ID shown in Apple Developer portal (e.g. "ABC1234DEF")
 *   APNS_TEAM_ID       — 10-char team ID from Apple Developer portal (e.g. "XYZ9876543")
 *   APNS_BUNDLE_ID     — app bundle ID: "mattfasullo.MediaDash"
 *
 * Required KV namespace binding (set in Cloudflare dashboard):
 *   DEVICE_TOKENS      — KV namespace; stores registered device tokens
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/register") {
      return handleRegister(request, env);
    }
    if (request.method === "POST" && url.pathname === "/webhook") {
      return handleWebhook(request, env);
    }

    return new Response("Not found", { status: 404 });
  },
};

// ---------------------------------------------------------------------------
// /register — MediaDash calls this on launch to store its device token
// ---------------------------------------------------------------------------

async function handleRegister(request, env) {
  if (!checkSecret(request, env)) {
    return new Response("Unauthorized", { status: 401 });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response("Bad request: invalid JSON", { status: 400 });
  }

  const { deviceToken, isProduction } = body;
  if (!deviceToken || typeof deviceToken !== "string") {
    return new Response("Bad request: missing deviceToken", { status: 400 });
  }

  // Store tokens as a JSON array in KV, keyed separately by environment
  const kvKey = isProduction ? "tokens_prod" : "tokens_dev";
  const existing = JSON.parse((await env.DEVICE_TOKENS.get(kvKey)) || "[]");

  if (!existing.includes(deviceToken)) {
    existing.push(deviceToken);
    await env.DEVICE_TOKENS.put(kvKey, JSON.stringify(existing));
  }

  return json({ success: true, environment: isProduction ? "production" : "development" });
}

// ---------------------------------------------------------------------------
// /webhook — Airtable automation calls this when a new docket record is created
// ---------------------------------------------------------------------------

async function handleWebhook(request, env) {
  if (!checkSecret(request, env)) {
    return new Response("Unauthorized", { status: 401 });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response("Bad request: invalid JSON", { status: 400 });
  }

  const { docketNumber, jobName, recordId } = body;
  if (!docketNumber) {
    return new Response("Bad request: missing docketNumber", { status: 400 });
  }

  // Send to both prod and dev token lists so development builds also receive pushes
  const prodTokens = JSON.parse((await env.DEVICE_TOKENS.get("tokens_prod")) || "[]");
  const devTokens  = JSON.parse((await env.DEVICE_TOKENS.get("tokens_dev"))  || "[]");

  const jwt = await generateAPNsJWT(env.APNS_TEAM_ID, env.APNS_KEY_ID, env.APNS_PRIVATE_KEY);

  const pushFn = (token, isProd) =>
    sendPush(token, docketNumber, jobName || "", recordId || "", jwt, env.APNS_BUNDLE_ID, isProd);

  const results = await Promise.allSettled([
    ...prodTokens.map((t) => pushFn(t, true)),
    ...devTokens.map((t)  => pushFn(t, false)),
  ]);

  const sent   = results.filter((r) => r.status === "fulfilled").length;
  const failed = results.filter((r) => r.status === "rejected").length;

  return json({ success: true, sent, failed, total: prodTokens.length + devTokens.length });
}

// ---------------------------------------------------------------------------
// APNs JWT (ES256)
// ---------------------------------------------------------------------------

async function generateAPNsJWT(teamId, keyId, privateKeyPEM) {
  const pemBody = privateKeyPEM
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");

  const keyBytes = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const now        = Math.floor(Date.now() / 1000);
  const headerB64  = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const payloadB64 = b64url(JSON.stringify({ iss: teamId, iat: now }));
  const toSign     = `${headerB64}.${payloadB64}`;

  const sigBytes = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(toSign)
  );

  return `${headerB64}.${payloadB64}.${b64urlBytes(new Uint8Array(sigBytes))}`;
}

// ---------------------------------------------------------------------------
// APNs HTTP/2 push
// ---------------------------------------------------------------------------

async function sendPush(deviceToken, docketNumber, jobName, recordId, jwt, bundleId, isProduction) {
  const host    = isProduction
    ? "https://api.push.apple.com"
    : "https://api.development.push.apple.com";

  const alertBody = jobName
    ? `Docket ${docketNumber}: ${jobName}`
    : `Docket ${docketNumber}`;

  const payload = {
    aps: {
      alert: { title: "New Docket Detected", body: alertBody },
      sound: "default",
    },
    docketNumber,
    jobName,
    recordId,
  };

  const response = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      Authorization: `bearer ${jwt}`,
      "apns-push-type": "alert",
      "apns-topic": bundleId,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const err = await response.json().catch(() => ({}));
    throw new Error(`APNs ${response.status}: ${JSON.stringify(err)}`);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function checkSecret(request, env) {
  return request.headers.get("X-MediaDash-Secret") === env.SHARED_SECRET;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function b64url(str) {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function b64urlBytes(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
