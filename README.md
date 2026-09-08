# EchoOrchestrator

Canonical deployment/orchestration project for the Echo stack.

## Configuration

EchoWeb and EchoService read `PlatformConfig/cfg_tbl_Setting` directly, resolving
nonblank environment overrides, their own `echo-web` / `echo-service` scope, the
parent `echo` scope, then `*`. Each service receives its own NocoDB API token.
The stack has no Identity configuration volume or shared-file startup dependency.

| Deployment input | Purpose |
| --- | --- |
| `NOCODB_BASE_URL` | Reach the NocoDB instance; base/table IDs are discovered by name |
| `ECHO_WEB_NOCODB_API_TOKEN` | EchoWeb's NocoDB token, passed as `NOCODB_API_TOKEN` |
| `ECHO_SERVICE_NOCODB_API_TOKEN` | EchoService's NocoDB token, passed as `NOCODB_API_TOKEN` |
| `MYSQL_*` | Initialize the MySQL container and provide current Echo pool credentials |
| `DB_*` passed to Web/Service | Process bootstrap; pool changes currently require restart |
| `PORT`, `MEDIA_ROOT`, volume mounts | Deployment topology; media reader/writer paths must agree |

`SETTINGS_MODE=platform` is explicit in canonical compose. There is no automatic
SQL fallback after a PlatformConfig failure. Runtime settings are cached for 30
seconds; process bootstrap (including database pools and listener ports) is not
hot-reloaded. Platform `trustedCIDR` belongs in `*`; EchoService uses it for its
webhook policy. Tokens must be available independently of Identity's local files.
A token is not a tenant authorization boundary.

EchoMedia reads only `PORT` and `MEDIA_ROOT` from its environment. It never read
`echo_tbl_Settings`, and needs no NocoDB token for these deployment invariants.
The old issue premise of migrating an EchoMedia SQL reader is superseded.

Database coordinates remain environment bootstrap in the current EchoWeb and
EchoService implementations. Moving them into `echo` rows requires a separate
startup/pool-lifecycle change in both consumers; do not remove their `DB_*` until
that exists. MySQL always needs its own bootstrap credentials. Existing numeric
service UIDs may also be needed for media/log-volume ownership; they are no
longer an Identity shared-file requirement. Do not recursively change live
volume ownership as part of this configuration cutover.

## Deployment gate and rollback

Merging this prepared configuration into `dev` does not authorize or establish a
live cutover. Before deploying:

1. Record the current images/commits, compose files and protected `.env`; back up
   the database with `mysqldump --single-transaction --routines` and export
   PlatformConfig. Keep the existing database/media volumes and credentials.
2. Deploy/verify Identity's canonical PlatformConfig and directory/session API.
   Verify the exact EchoWeb and EchoService images both support platform mode.
   Follow [EchoService #10](https://github.com/localsplash/EchoService/issues/10)
   and [EchoWeb #21](https://github.com/localsplash/EchoWeb/issues/21).
3. Copy reviewed legacy settings to canonical scopes without exposing secrets:
   Echo SQL `*` generally maps to `echo`, `web` to `echo-web`, and `service` to
   `echo-service`. Use `*` only for intentionally platform-wide settings such as
   `PARENT_DOMAIN` and `trustedCIDR`. Empty seed rows do not count as configured.
   Preserve all legacy rows. Resolve duplicates and verify required keys against
   each consumer's `SETTING_KEYS` and policy settings.
4. Provide the three NocoDB inputs above and verify each token can read the named
   base/table. Existing `.env` files are never overwritten by the installer;
   append the new values securely. The database's current `MYSQL_PASSWORD` must
   continue to match its initialized volume; changing `.env` does not rotate it.
5. Set `ECHO_SERVICE_BASE_URL=http://echo-service:8080` for EchoWeb. Set the public
   `APP_BASE_URL`, `MEDIA_BASE_URL` (for example `https://media.echo.wisp.net`) and
   any private media proxy origin in the proper scope. The production overlay no
   longer silently pins a public media URL over the PlatformConfig value.
6. Render compose with `docker compose config --quiet`, then run staging startup,
   settings refresh and deliberate NocoDB-unavailability checks. Validate real
   sign-in, tenant/number authorization, inbound carrier webhooks, outbound
   messages and media retrieval before promoting images. Store results in #11.

For rollback, restore the recorded prior service images **and compose/.env**;
retain the original Identity configuration volume and legacy NocoDB/SQL rows
until the rollback deadline. The new compose stops mounting that volume; it does
not delete it. Current Web/Service also retain an explicit `SETTINGS_MODE=legacy`
compatibility path, but it must be deliberately configured with its legacy
NocoDB coordinates and DB environment; never treat an outage as a mode switch.

[EchoDatabase #8](https://github.com/localsplash/EchoDatabase/issues/8) stays blocked
until all deployed readers are verified, other readers are inventoried and the
agreed rollback window expires. No DROP migration belongs in this deployment.
Live validation and rollback-window completion are still outstanding.

## Schema migrations

`../EchoDatabase/init` is mounted into the database container at
`/docker-entrypoint-initdb.d`, which MySQL runs **only when initialising an
empty data directory**. Files added after the first `up` are silently skipped —
which is how `009_settings.sql` sat in the repo while a running database had no
`echo_tbl_Settings`.

So a one-shot `echo-migrate` service applies the same files, in order, against
the database as it actually is, recording each in `echo_tbl_SchemaMigration`.
`echo-service` and `echo-web` wait on it completing.

The schema files are **not** idempotent — 006/007/008 are bare `ALTER TABLE ...
ADD COLUMN`, and 001/003 seed lookup tables with bare `INSERT`. The ledger is
the entire safety mechanism: each file runs exactly once. A database that
already has the schema but no ledger is therefore **baselined** — every current
file recorded as applied without being run, loudly, once — because initdb
already ran them and there is no way to ask MySQL which.

## First install

```bash
scripts/install.sh          # writes protected .env once; does not start services
# Fill in NocoDB URL and both service tokens in .env.
# Prepare PlatformConfig rows and complete the deployment gate above.
docker compose config --quiet
docker compose up -d --build
```

The installer generates MySQL bootstrap passwords for a fresh volume only. It
never overwrites an existing `.env`, initializes containers or rotates an existing
database password. Restore the protected original credentials for an existing
volume; do not run a fresh-install password generation as a recovery procedure.

## Stack

- EchoWeb
- EchoService
- EchoDatabase
- EchoMedia

## Production model

On `proxy.wisp.net`, the canonical edge model is:

- **Nginx Proxy Manager/openresty** owns the public Echo hostnames and TLS termination
- **EchoOrchestrator** runs the containers on the shared `echo-net` Docker network so NPM can proxy directly to service names
- Localhost-only published ports remain useful for direct service checks and fallback/debugging

## Hostname mapping

- `echo.wisp.net` → NPM/openresty → `echo-web:3160`
- `io.echo.wisp.net` → NPM/openresty → `echo-service:8080`
- `media.echo.wisp.net` → NPM/openresty → `echo-media:8082`

## Docker networks

- `echo-net` → shared internal Echo service network
- `dokku_network` → optional external/public integration network

## Volumes

Production uses external Docker volumes:

- DB volume: `echomessagingservice_echo_database_data`
- Media volume: `echo_media_data`

## Production compose

Use:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

## NPM configs

Live NPM proxy-host records on `proxy.wisp.net` should be the source of truth for the Echo edge.

- `echo.wisp.net` uses Let's Encrypt cert id/path `npm-9`
- `io.echo.wisp.net` uses Let's Encrypt cert id/path `npm-11`
- `media.echo.wisp.net` uses Let's Encrypt cert id/path `npm-12`

The files under `deploy/nginx/` are historical/fallback references only; do not treat them as the canonical production edge unless NPM is intentionally bypassed.

## Deployment portability notes

For a second server with different root URL structure:

- update the public hostnames
- update `MEDIA_BASE_URL` in the appropriate PlatformConfig scope
- create/update NPM proxy hosts and attach certificates for that environment
- keep the localhost proxy-port pattern for service checks unless there is a reason to change it
- preserve external volume strategy if you want durable DB/media state

## PBX boundary

Identity owns business users/tenants and shared-number access. The installed
OfficePulse/Asterisk PBX owns extensions, queues and applied DID routes, accessed
through OfficePulseAidaIntegration's API. EchoOrchestrator does not deploy an
AidaAdmin-to-Asterisk synchronization worker or a separate AidaOfficePbxAdmin.
AidaAgent and AidaHandset are deferred. Deprecated AidaControl and the historical
AidaInfrastructureSetupInstructions repository are not deployment dependencies.
