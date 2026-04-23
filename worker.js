/**
 * MIEI HOME — Update Server
 * Cloudflare Worker + D1 database
 *
 * Endpoints:
 *   GET  /version.json          → current release manifest (Pi polls this)
 *   GET  /firmware/:type/:file  → redirect to R2 firmware binary
 *   POST /api/ingest            → receive diagnostic reports from Pi
 *   GET  /admin/reports         → developer admin view (auth required)
 *   POST /admin/release         → publish a new firmware version (auth required)
 */

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // ── Public endpoints (no auth) ──────────────────────────────────────────

    if (path === "/version.json" && request.method === "GET") {
      return handleVersionCheck(env);
    }

    if (path.startsWith("/firmware/") && request.method === "GET") {
      return handleFirmwareDownload(path, env);
    }

    if (path === "/api/ingest" && request.method === "POST") {
      return handleDiagnosticIngest(request, env);
    }

    if (path === "/api/ping") {
      return json({ ok: true, ts: Date.now() });
    }

    // ── Admin endpoints (Bearer token required) ─────────────────────────────

    if (path.startsWith("/admin/")) {
      const authResult = checkAuth(request, env);
      if (!authResult.ok) {
        return json({ error: "Unauthorized" }, 401);
      }
      if (path === "/admin/release" && request.method === "POST") {
        return handleRelease(request, env);
      }
      if (path === "/admin/reports" && request.method === "GET") {
        return handleListReports(url, env);
      }
      if (path === "/admin/devices" && request.method === "GET") {
        return handleListDevices(env);
      }
    }

    return json({ error: "Not found" }, 404);
  },
};

// =============================================================================
// GET /version.json
// Pi calls this when customer taps "Check for updates"
// Returns current firmware versions for all component types
// =============================================================================
async function handleVersionCheck(env) {
  const row = await env.DB.prepare(
    "SELECT * FROM releases ORDER BY created_at DESC LIMIT 1"
  ).first();

  if (!row) {
    return json({ error: "No release found" }, 404);
  }

  const manifest = {
    version: row.version,
    released_at: row.created_at,
    components: JSON.parse(row.components),
    // components format:
    // {
    //   "pi": { "version": "1.0.1", "url": "/firmware/pi/miehome-pi-1.0.1.tar.gz" },
    //   "esp32_switch": { "version": "1.0.1", "url": "/firmware/esp32/sonoff_switch-1.0.1.bin" },
    //   "esp32_voice": { "version": "1.0.1", "url": "/firmware/esp32/voice_node-1.0.1.bin" },
    //   "esp32_sensor": { "version": "1.0.1", "url": "/firmware/esp32/sensor_pack-1.0.1.bin" }
    // }
    changelog: row.changelog,
  };

  return json(manifest, 200, {
    "Cache-Control": "public, max-age=300", // Cache 5 min at Cloudflare edge
  });
}

// =============================================================================
// GET /firmware/:type/:filename
// Redirects to Cloudflare R2 signed URL for actual binary download
// Keeps firmware binaries off the Worker and in R2 object storage
// =============================================================================
async function handleFirmwareDownload(path, env) {
  // path: /firmware/esp32/sonoff_switch-1.0.1.bin
  const parts = path.split("/").filter(Boolean); // ["firmware","esp32","file.bin"]
  if (parts.length < 3) {
    return json({ error: "Invalid firmware path" }, 400);
  }

  const r2Key = parts.slice(1).join("/"); // "esp32/sonoff_switch-1.0.1.bin"

  // Log the download (anonymised — no IP stored, just count + device type)
  ctx?.waitUntil(
    env.DB.prepare(
      "INSERT INTO download_log (r2_key, ts) VALUES (?, ?)"
    ).bind(r2Key, Date.now()).run()
  );

  // Redirect to R2 public URL (set your R2 bucket as public or use signed URLs)
  const r2BaseUrl = env.R2_PUBLIC_URL; // e.g. https://firmware.miehome.io
  return Response.redirect(`${r2BaseUrl}/${r2Key}`, 302);
}

// =============================================================================
// POST /api/ingest
// Receives anonymised diagnostic report from customer Pi
// Stores in D1 — no personal data, no video, hashed serial only
// =============================================================================
async function handleDiagnosticIngest(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  // Validate required fields
  const required = ["pi_serial_hash", "version", "timestamp"];
  for (const field of required) {
    if (!body[field]) {
      return json({ error: `Missing field: ${field}` }, 400);
    }
  }

  // Sanitise — only store what we explicitly allow
  const report = {
    pi_hash: String(body.pi_serial_hash).substring(0, 12),
    version: String(body.version).substring(0, 20),
    cpu_temp: typeof body.cpu_temp_c === "number" ? body.cpu_temp_c : null,
    cpu_pct: typeof body.cpu_percent === "number" ? body.cpu_percent : null,
    mem_pct: body.memory?.percent ?? null,
    disk_pct: body.disk?.percent ?? null,
    disk_free_gb: body.disk?.free_gb ?? null,
    device_count: typeof body.device_count === "number" ? body.device_count : null,
    offline_devices: typeof body.offline_devices === "number" ? body.offline_devices : null,
    services: body.services ? JSON.stringify(body.services) : null,
    ts: Math.floor(Date.now() / 1000),
    // Cloudflare gives us country code — useful for support, privacy-safe
    country: request.cf?.country ?? null,
  };

  await env.DB.prepare(`
    INSERT INTO diagnostic_reports
      (pi_hash, version, cpu_temp, cpu_pct, mem_pct, disk_pct,
       disk_free_gb, device_count, offline_devices, services, country, ts)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    report.pi_hash, report.version, report.cpu_temp, report.cpu_pct,
    report.mem_pct, report.disk_pct, report.disk_free_gb,
    report.device_count, report.offline_devices,
    report.services, report.country, report.ts
  ).run();

  return json({ received: true, message: "Report stored. Thank you." });
}

// =============================================================================
// POST /admin/release  (auth required)
// Called by GitHub Action after a successful build
// Body: { version, changelog, components: { pi: {...}, esp32_switch: {...}, ... } }
// =============================================================================
async function handleRelease(request, env) {
  const body = await request.json();
  const { version, changelog, components } = body;

  if (!version || !components) {
    return json({ error: "Missing version or components" }, 400);
  }

  await env.DB.prepare(`
    INSERT INTO releases (version, changelog, components, created_at)
    VALUES (?, ?, ?, ?)
  `).bind(
    version,
    changelog ?? "",
    JSON.stringify(components),
    new Date().toISOString()
  ).run();

  return json({ published: true, version });
}

// =============================================================================
// GET /admin/reports  (auth required)
// Returns recent diagnostic reports for developer admin panel
// =============================================================================
async function handleListReports(url, env) {
  const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "50"), 200);
  const piHash = url.searchParams.get("pi");

  let query = "SELECT * FROM diagnostic_reports ORDER BY ts DESC LIMIT ?";
  const params = [limit];

  if (piHash) {
    query = "SELECT * FROM diagnostic_reports WHERE pi_hash = ? ORDER BY ts DESC LIMIT ?";
    params.unshift(piHash);
  }

  const { results } = await env.DB.prepare(query).bind(...params).all();
  return json({ reports: results, count: results.length });
}

// =============================================================================
// GET /admin/devices  (auth required)
// Summary of all unique Pi hashes that have sent reports
// =============================================================================
async function handleListDevices(env) {
  const { results } = await env.DB.prepare(`
    SELECT
      pi_hash,
      COUNT(*) as report_count,
      MAX(ts) as last_seen,
      MIN(version) as earliest_version,
      MAX(version) as latest_version,
      AVG(cpu_temp) as avg_cpu_temp,
      country
    FROM diagnostic_reports
    GROUP BY pi_hash
    ORDER BY last_seen DESC
  `).all();

  return json({ devices: results, count: results.length });
}

// =============================================================================
// Helpers
// =============================================================================
function checkAuth(request, env) {
  const auth = request.headers.get("Authorization") ?? "";
  const token = auth.replace("Bearer ", "").trim();
  // ADMIN_TOKEN set as Cloudflare secret: wrangler secret put ADMIN_TOKEN
  if (!env.ADMIN_TOKEN || token !== env.ADMIN_TOKEN) {
    return { ok: false };
  }
  return { ok: true };
}

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...extraHeaders,
    },
  });
}
