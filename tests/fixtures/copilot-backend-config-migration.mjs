// Actual pinned backend migration, in an explicitly isolated remote trial only.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync, realpathSync } from "node:fs";
import { join, basename, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = realpathSync(process.argv[2]);
assert.ok(basename(root).startsWith("copilot-dogfood-"));
const home = join(root, "migration-check");
assert.notEqual(resolve(home), resolve(process.env.HOME ?? "", ".local/share/copilot-api"));
process.env.COPILOT_API_HOME = home;
process.env.COPILOT_API_SQLITE_DB_PATH = join(home, "usage.sqlite");
delete process.env.COPILOT_API_GITHUB_TOKEN;
mkdirSync(home, { recursive: true, mode: 0o700 });
const original = {
  responsesTransport: { headersTimeoutMsV2: 123456, streamInactivityTimeoutMs: 234567 },
  unrelated: { keep: "fixture" },
  auth: { adminApiKey: "fixture-admin-not-a-real-credential" },
};
writeFileSync(join(home, "config.json"), JSON.stringify(original), { mode: 0o600 });
const candidate = join(root, "2.5.2/pkg/node_modules/@jeffreycao/copilot-api");
assert.equal(JSON.parse(readFileSync(join(candidate, "package.json"))).version, "2.5.2");
const module = await import(pathToFileURL(join(candidate, "dist/config-Dj2ZvQuL.js")));
module.j(); // mergeConfigWithDefaults reads/writes only the isolated COPILOT_API_HOME.
const migrated = JSON.parse(readFileSync(join(home, "config.json")));
assert.equal(migrated.upstreamTransport.headersTimeoutMs, 123456);
assert.equal(migrated.upstreamTransport.streamInactivityTimeoutMs, 234567);
assert.equal(migrated.responsesTransport, undefined);
assert.equal(migrated.upstreamTransport.headersTimeoutMsV2, undefined);
assert.deepEqual(migrated.unrelated, original.unrelated);
assert.equal(migrated.auth.adminApiKey, original.auth.adminApiKey);
console.log(JSON.stringify({ ok: true, actual_backend: "2.5.2", custom_deadlines_preserved: true,
  legacy_keys_migrated: true, unrelated_config_preserved: true, existing_admin_key_preserved: true }));
