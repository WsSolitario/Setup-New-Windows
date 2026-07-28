'use strict';

require('dotenv').config();

const fs = require('node:fs/promises');
const path = require('node:path');
const express = require('express');
const helmet = require('helmet');
const { Pool } = require('pg');

const app = express();
const port = parseInteger(process.env.PORT, 3000);
const trustProxy = parseInteger(process.env.TRUST_PROXY, 1);
const templatesDirectory = path.join(__dirname, '..', 'powershell');
const ninitePath = path.resolve(process.env.NINITE_PATH || path.join(__dirname, '..', 'artifacts', 'ninite.exe'));
const setupToken = process.env.SETUP_TOKEN || '';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.PGSSL === 'true' ? { rejectUnauthorized: true } : false,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000
});

app.set('trust proxy', trustProxy);
app.disable('x-powered-by');
app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json({ limit: '16kb' }));

app.get('/health', async (_req, res, next) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok' });
  } catch (error) {
    next(error);
  }
});

app.get('/setup.ps1', async (req, res, next) => {
  try {
    const script = await renderPowerShell('setup.ps1', req, {
      LOCAL_ADMIN_USERNAME: requiredEnvironment('LOCAL_ADMIN_USERNAME'),
      LOCAL_ADMIN_FULL_NAME: process.env.LOCAL_ADMIN_FULL_NAME || 'Nombre Plasencia'
    });
    sendPowerShell(res, script, 'setup.ps1');
  } catch (error) {
    next(error);
  }
});

app.get('/stage2.ps1', async (req, res, next) => {
  if (!isAuthorized(req, true)) return res.status(401).json({ error: 'token requerido' });
  try {
    const script = await renderPowerShell('stage2.ps1', req, {
      SETUP_TOKEN: requiredEnvironment('SETUP_TOKEN')
    });
    sendPowerShell(res, script, 'stage2.ps1');
  } catch (error) {
    next(error);
  }
});

app.get('/ninite.exe', async (_req, res, next) => {
  if (!isAuthorized(_req)) return res.status(401).json({ error: 'token requerido' });
  try {
    await fs.access(ninitePath);
    res.set({
      'Cache-Control': 'private, no-store',
      'Content-Type': 'application/vnd.microsoft.portable-executable'
    });
    res.sendFile(ninitePath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return res.status(404).json({ error: 'ninite.exe no esta disponible en el servidor' });
    }
    next(error);
  }
});

app.post('/api/register', async (req, res, next) => {
  if (!isAuthorized(req)) return res.status(401).json({ error: 'token requerido' });
  const serialNumber = normalizeText(req.body?.serial_number, 128);
  const hostname = normalizeText(req.body?.hostname, 255);

  if (!serialNumber || !hostname) {
    return res.status(400).json({ error: 'serial_number y hostname son obligatorios' });
  }

  try {
    const result = await pool.query(
      `INSERT INTO workstations (serial_number, hostname, status)
       VALUES ($1, $2, 'registrado')
       ON CONFLICT (serial_number) DO UPDATE
       SET hostname = EXCLUDED.hostname
       RETURNING id, serial_number, hostname, status, created_at, updated_at,
                 (xmax = 0) AS inserted`,
      [serialNumber, hostname]
    );
    const workstation = result.rows[0];
    const statusCode = workstation.inserted ? 201 : 200;
    delete workstation.inserted;
    res.status(statusCode).json(workstation);
  } catch (error) {
    next(error);
  }
});

app.post('/api/status', async (req, res, next) => {
  if (!isAuthorized(req)) return res.status(401).json({ error: 'token requerido' });
  const serialNumber = normalizeText(req.body?.serial_number, 128);
  const status = normalizeStatus(req.body?.status);

  if (!serialNumber || !status) {
    return res.status(400).json({
      error: 'serial_number y status son obligatorios; status solo admite letras, numeros, guion y guion bajo'
    });
  }

  try {
    const result = await pool.query(
      `UPDATE workstations
       SET status = $2
       WHERE serial_number = $1
       RETURNING id, serial_number, hostname, status, created_at, updated_at`,
      [serialNumber, status]
    );
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'equipo no registrado' });
    }
    res.json(result.rows[0]);
  } catch (error) {
    next(error);
  }
});

app.use((_req, res) => {
  res.status(404).json({ error: 'ruta no encontrada' });
});

app.use((error, _req, res, _next) => {
  console.error(error);
  if (error instanceof SyntaxError && error.status === 400 && 'body' in error) {
    return res.status(400).json({ error: 'JSON no valido' });
  }
  res.status(500).json({ error: 'error interno del servidor' });
});

const server = app.listen(port, () => {
  console.log(`Workstation Setup API escuchando en el puerto ${port}`);
});

async function renderPowerShell(fileName, req, values = {}) {
  const baseUrl = getPublicBaseUrl(req);
  let template = await fs.readFile(path.join(templatesDirectory, fileName), 'utf8');
  const replacements = { API_BASE_URL: baseUrl, ...values };

  for (const [key, value] of Object.entries(replacements)) {
    template = template.replaceAll(`{{${key}}}`, escapePowerShellString(value));
  }
  return template;
}

function getPublicBaseUrl(req) {
  const rawUrl = process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
  const parsedUrl = new URL(rawUrl);
  if (!['http:', 'https:'].includes(parsedUrl.protocol)) {
    throw new Error('PUBLIC_BASE_URL debe usar http o https');
  }
  return rawUrl.replace(/\/$/, '');
}

function sendPowerShell(res, script, fileName) {
  res.set({
    'Cache-Control': 'no-store',
    'Content-Disposition': `inline; filename="${fileName}"`,
    'Content-Type': 'text/plain; charset=utf-8'
  });
  res.send(script);
}

function escapePowerShellString(value) {
  return String(value).replaceAll("'", "''");
}

function isAuthorized(req, allowQueryToken = false) {
  if (!setupToken) return false;
  const suppliedToken = req.get('X-Setup-Token') || (allowQueryToken ? req.query.token : '');
  if (typeof suppliedToken !== 'string' || suppliedToken.length !== setupToken.length) return false;
  return require('node:crypto').timingSafeEqual(Buffer.from(suppliedToken), Buffer.from(setupToken));
}

function normalizeText(value, maxLength) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  if (!normalized || normalized.length > maxLength || /[\u0000-\u001f]/.test(normalized)) return null;
  return normalized;
}

function normalizeStatus(value) {
  const normalized = normalizeText(value, 64);
  return normalized && /^[a-zA-Z0-9_-]+$/.test(normalized) ? normalized : null;
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Falta la variable de entorno ${name}`);
  return value;
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

async function shutdown(signal) {
  console.log(`${signal} recibido; cerrando conexiones`);
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
