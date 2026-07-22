#!/usr/bin/env node
// Target-owned reference adapter for VERIFY_CLEAN_COMMAND.
// It is intentionally product-neutral: targets provide the two connection
// URLs, expected values, and read-only SQL probes; no FeedbackOps names leak.
import { execFileSync } from "node:child_process";

const appUrl = process.env.VERIFY_CLEAN_APP_DATABASE_URL || process.env.VERIFY_DATABASE_URL;
const migrateUrl = process.env.VERIFY_CLEAN_MIGRATE_DATABASE_URL || appUrl;
const sentinelExpected = process.env.VERIFY_CLEAN_SENTINEL_EXPECTED;
const migrationExpected = process.env.VERIFY_CLEAN_MIGRATION_HASH_EXPECTED;
const sentinelQuery = process.env.VERIFY_CLEAN_SENTINEL_QUERY;
const migrationQuery = process.env.VERIFY_CLEAN_MIGRATION_HASH_QUERY;
if (![appUrl, migrateUrl, sentinelExpected, migrationExpected, sentinelQuery, migrationQuery].every(Boolean)) {
  console.error("VERIFY_CLEAN_COMMAND requires app/migrate URLs, expected values, and two target-owned read-only SQL queries"); process.exit(2);
}
function psqlEnv(connection) {
  const parsed = new URL(connection);
  const env = { ...process.env, PGDATABASE: decodeURIComponent(parsed.pathname.replace(/^\//, "")) };
  if (parsed.hostname) env.PGHOST = parsed.hostname;
  if (parsed.port) env.PGPORT = parsed.port;
  if (parsed.username) env.PGUSER = decodeURIComponent(parsed.username);
  if (parsed.password) env.PGPASSWORD = decodeURIComponent(parsed.password);
  // Preserve supported libpq TLS settings without passing the URL itself to
  // psql argv. Refuse an unrecognized URL option rather than silently losing
  // security semantics (for example a custom CA or client certificate).
  const libpqOptions = {
    sslmode: "PGSSLMODE", sslrootcert: "PGSSLROOTCERT", sslcert: "PGSSLCERT",
    sslkey: "PGSSLKEY", sslcrl: "PGSSLCRL", sslcrldir: "PGSSLCRLDIR",
    sslpassword: "PGSSLPASSWORD", ssl_min_protocol_version: "PGSSLMINPROTOCOLVERSION",
    ssl_max_protocol_version: "PGSSLMAXPROTOCOLVERSION", sslnegotiation: "PGSSLNEGOTIATION",
    sslcompression: "PGSSLCOMPRESSION", sslsni: "PGSSLSNI"
  };
  for (const [key, value] of parsed.searchParams) {
    const environmentKey = libpqOptions[key];
    if (!environmentKey) throw new Error(`unsupported database URL option: ${key}`);
    if (!value) throw new Error(`empty database URL option: ${key}`);
    env[environmentKey] = value;
  }
  return env;
}
function query(url, sql) {
  // Keep connection material out of argv: local process inspection can expose
  // argv even when child stderr is suppressed. libpq reads these PG* values.
  return execFileSync("psql", ["-Atqc", sql], { encoding: "utf8", env: psqlEnv(url), stdio: ["ignore", "pipe", "pipe"] }).trim();
}
try {
  const role = query(appUrl, "select current_user || '|' || (select rolsuper::text from pg_roles where rolname=current_user)");
  const [name, superuser] = role.split("|");
  process.stdout.write(JSON.stringify({ checks: [
    { code: "sentinel", expected: sentinelExpected, actual: query(appUrl, sentinelQuery) },
    { code: "migration_hash", expected: migrationExpected, actual: query(migrateUrl, migrationQuery) }
  ], role: { name, superuser: superuser === "true" } }) + "\n");
} catch (_) {
  // Do not print child-process diagnostics: psql errors can include argv,
  // connection URLs, usernames, or password-bearing connection strings.
  console.error("clean probe failed: target-owned database checks did not complete");
  process.exit(1);
}
