// PostgreSQL local para desarrollo, sin Docker ni instaladores: npm run db:local
// Los datos se guardan en backend/.pgdata. Ctrl+C para detenerlo.
import fs from 'node:fs';
import EmbeddedPostgres from 'embedded-postgres';

const dir = new URL('../.pgdata', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const pg = new EmbeddedPostgres({ databaseDir: dir, user: 'geotrack', password: 'geotrack', port: 5432, persistent: true,
  initdbFlags: ['--encoding=UTF8', '--locale=C'],
});

if (!fs.existsSync(dir)) {
  await pg.initialise();
  await pg.start();
  await pg.createDatabase('geotrack');
} else {
  await pg.start();
}
console.log('PostgreSQL local en postgres://geotrack:geotrack@localhost:5432/geotrack');
process.on('SIGINT', async () => { await pg.stop(); process.exit(0); });
