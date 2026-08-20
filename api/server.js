'use strict';

/**
 * server.js
 * -----------------------------------------------------------------------------
 * Express API for the Regional Health admissions & patient-lookup service.
 *
 * Endpoints:
 *   GET  /api/patients/recent        Recent patients widget
 *   GET  /api/patients/search        Patient lookup by last name
 *   POST /api/hospitals/:id/admit    Admit a patient (decrement bed count)
 *   GET  /api/patients/export        Full patient export for the analytics team
 *   GET  /api/audit/ping             Mongo audit-store health probe
 *   GET  /healthz                    Liveness — process is up
 *   GET  /readyz                     Readiness — DB reachable, pool OK, secret resolved
 *   GET  /debug/secret-source        Where DB creds came from (ARN + version only)
 *   GET  /metrics                    Prometheus metrics
 */

const express = require('express');
const client = require('prom-client');
const { loadDbCredentials, getSecretSource } = require('./secrets');
const { getPool, getMongo, initDatabase, checkDbReadiness } = require('./database');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 3000);

// ---------------------------------------------------------------------------
// Prometheus metrics
// ---------------------------------------------------------------------------
const register = new client.Registry();
register.setDefaultLabels({ app: 'capacity-api' });

// Default process/GC/heap metrics.
client.collectDefaultMetrics({ register, gcDurationBuckets: [0.001, 0.01, 0.1, 1, 2, 5] });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const dbErrorsTotal = new client.Counter({
  name: 'db_errors_total',
  help: 'Total number of database errors by type',
  labelNames: ['route', 'code'],
  registers: [register],
});

// Per-request timing + counting middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.baseUrl + req.route.path : req.path;
    const labels = { method: req.method, route, status_code: res.statusCode };
    end(labels);
    httpRequestsTotal.inc(labels);
  });
  next();
});

// ---------------------------------------------------------------------------
// Health & metrics
// ---------------------------------------------------------------------------
let secretLoadFailed = false;
let secretLoadError = null;

app.get('/healthz', (_req, res) => {
  res.status(200).json({ status: 'ok' });
});

// Backward-compatible alias for older local checks.
app.get('/health', (_req, res) => {
  res.redirect(307, '/healthz');
});

app.get('/readyz', async (_req, res) => {
  if (secretLoadFailed) {
    return res.status(503).json({
      status: 'not_ready',
      reason: 'secret_failed',
      message: secretLoadError,
    });
  }

  const check = await checkDbReadiness();
  if (!check.ready) {
    return res.status(503).json({ status: 'not_ready', reason: check.reason });
  }

  res.status(200).json({ status: 'ready' });
});

app.get('/debug/secret-source', (_req, res) => {
  res.json(getSecretSource());
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// ---------------------------------------------------------------------------
// Recent patients widget
// ---------------------------------------------------------------------------
app.get('/api/patients/recent', async (_req, res) => {
  try {
    const pool = getPool();
    const [rows] = await pool.query(
      `SELECT id, first_name, last_name, email, diagnosis, created_at
       FROM patients
       ORDER BY id DESC
       LIMIT 50`
    );
    res.json({ count: rows.length, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/recent', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Patient lookup by last name
// ---------------------------------------------------------------------------
app.get('/api/patients/search', async (req, res) => {
  const lastName = req.query.lastName || '';
  try {
    const pool = getPool();
    const [rows] = await pool.query(
      `SELECT id, first_name, last_name, email, diagnosis, created_at
       FROM patients
       WHERE last_name = ?
       ORDER BY id
       LIMIT 51`,
      [lastName]
    );
    const data = rows.slice(0, 50);
    res.json({
      count: data.length,
      returnedCount: data.length,
      hasMore: rows.length > 50,
      lastName,
      data,
    });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/search', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Admit a patient to a hospital (decrement available beds).
// We update the bed count, then notify the regional bed registry that the
// count changed before finalizing, so the two systems stay consistent.
// ---------------------------------------------------------------------------
app.post('/api/hospitals/:id/admit', async (req, res) => {
  const hospitalId = Number(req.params.id);
  const pool = getPool();
  try {
    const [result] = await pool.query(
      `UPDATE hospitals
       SET available_beds = available_beds - 1
       WHERE id = ? AND available_beds > 0`,
      [hospitalId]
    );

    if (result.affectedRows === 0) {
      return res.status(409).json({ error: 'NO_BEDS_AVAILABLE', hospitalId });
    }

    // Notify after the atomic decrement has committed so the hospital row lock
    // is not held during the simulated external network round trip.
    await notifyBedRegistry(hospitalId);

    res.json({ status: 'admitted', hospitalId });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/hospitals/:id/admit', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// Stand-in for the external registry client used by the admit flow.
function notifyBedRegistry(_hospitalId) {
  return new Promise((r) => setTimeout(r, 500));
}

// ---------------------------------------------------------------------------
// Full patient export for the analytics/ETL team.
// ---------------------------------------------------------------------------
app.get('/api/patients/export', async (_req, res) => {
  try {
    const pool = getPool();
    const batchSize = 500;
    let lastId = 0;
    let firstRow = true;

    const [[{ count }]] = await pool.query('SELECT COUNT(*) AS count FROM patients');

    res.setHeader('Content-Type', 'application/json');
    res.write(`{"count":${count},"data":[`);

    while (!res.destroyed) {
      const [rows] = await pool.query(
        `SELECT *
         FROM patients
         WHERE id > ?
         ORDER BY id
         LIMIT ?`,
        [lastId, batchSize]
      );

      if (rows.length === 0) break;

      for (const row of rows) {
        lastId = row.id;
        const chunk = `${firstRow ? '' : ','}${JSON.stringify(row)}`;
        firstRow = false;
        if (!res.write(chunk)) {
          await new Promise((resolve) => res.once('drain', resolve));
        }
      }
    }

    if (!res.destroyed) res.end(']}');
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/export', code: err.code || 'UNKNOWN' });
    if (res.headersSent) {
      res.destroy(err);
    } else {
      res.status(500).json({ error: err.code || 'ERROR', message: err.message });
    }
  }
});

// ---------------------------------------------------------------------------
// Mongo audit-store health probe
// ---------------------------------------------------------------------------
app.get('/api/audit/ping', async (_req, res) => {
  try {
    const db = await getMongo();
    const result = await db.command({ ping: 1 });
    res.json({ mongo: result });
  } catch (err) {
    res.status(500).json({ error: 'MONGO_ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Boot — resolve DB credentials, initialize MySQL, then listen
// ---------------------------------------------------------------------------
async function start() {
  try {
    const credentials = await loadDbCredentials();
    await initDatabase(credentials);
  } catch (err) {
    secretLoadFailed = true;
    secretLoadError = err.message;
    // eslint-disable-next-line no-console
    console.error(
      `DB credential bootstrap failed: ${err.message} — /readyz will return 503`
    );
  }

  app.listen(PORT, () => {
    const source = getSecretSource();
    // eslint-disable-next-line no-console
    console.log(
      `capacity-api listening on :${PORT} (metrics at /metrics, secret arn=${source.arn})`
    );
  });
}

start().catch((err) => {
  // eslint-disable-next-line no-console
  console.error('Fatal boot error:', err);
  process.exit(1);
});
