import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : undefined,
  max: 10,
});

export async function migrate() {
  const sql = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
  await pool.query(sql);
}

export const query = (text, params) => pool.query(text, params);
