import { loadConfig } from './config.mjs';
import { createCompanion } from './server.mjs';

process.umask(0o077);
try {
  const config = loadConfig();
  const server = createCompanion(config);
  server.on('error', () => {
    console.error('Drive companion could not bind its private HTTP listener.');
    process.exitCode = 1;
  });
  server.listen(config.port, config.host, () => {
    console.log('Drive companion is listening on its private HTTP listener.');
  });
  function shutdown() {
    server.close(error => { if (error) process.exitCode = 1; });
    setTimeout(() => { server.closeAllConnections(); }, 5_000).unref();
  }
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
} catch (error) {
  // Config errors identify only the variable; database and other diagnostics stay private.
  const message = /^Missing or invalid [A-Z_]+$/.test(error.message)
    ? error.message : 'Drive companion startup failed.';
  console.error(message);
  process.exitCode = 1;
}
