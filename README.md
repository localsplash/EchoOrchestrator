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

PlatformConfig is the only supported settings source. The retired
`SETTINGS_MODE` selector and SQL/IdentityBase fallback readers are removed. Runtime settings are cached for 30
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

## Canonical Dev deployment and cleanup

The owner has explicitly designated `dockerappvm01-dev` as disposable development
and authorized deletion of obsolete objects. The previous preservation and
rollback-window requirements do not apply to this Dev cutover. Replace legacy
readers first, then apply the retirement migration and remove unused stacks;
do not maintain a second authority or compatibility path for discarded data.

1. Build the current `dev` versions of Identity, AidaAdmin, OfficePulse integration
   and Echo consumers. Verify their unit/build checks before replacement.
2. Supply each Echo consumer's own NocoDB URL/token, actual DB pool coordinates,
   and required canonical scoped settings. Set EchoWeb's private
   `ECHO_SERVICE_BASE_URL` and `MEDIA_INTERNAL_BASE_URL`; media access goes through
   its authenticated proxy. Listener ports and media mount paths stay deployment
   environment, not hot-reloaded settings.
3. Recreate the Dev containers and verify Identity, Admin, Echo and OfficePulse
   API health. OfficePulse PBX inventory needs an actual PBX read account and
   reviewed tenant mapping; this server does not contain the external PBX.
4. Apply EchoDatabase's `013_retire_legacy_configuration_and_auth.sql` after
   deploying consumers without legacy readers. It drops the retired Echo SQL
   settings, local authentication and ID-mapping tables. Keep the active SMS data
   and schema ledger; they are current application objects, not rollback copies.
5. Delete obsolete Aida PBX desired-state tables only with the matching Admin and
   OfficePulse cleanup, which removes their readers. Remove the unused `aida_db`
   schema once every runtime consumer points at `aidacalls_db`.
6. Route the natural Dev hostnames to the canonical containers. Remove old public
   raw EchoMedia/EchoService proxy objects. Retire the duplicate old Echo,
   Identity and NocoDB stacks and their unused volumes after resolving actual
   dependencies. Do not remove a volume still mounted by the canonical services.
7. Verify central authentication, current tenant/number access, database queries,
   authenticated media and rejected cross-tenant access. Validate the obsolete
   objects are absent and record deployed commit/image IDs in issue #11.

The host's active operator Compose files are under `/opt/platform-local/` and its
protected environment files stay outside source control. Do not print credentials
or render full secret-bearing Compose configuration in logs. User authorization
here is for this Dev host, not a destructive reset of other environments or the
external Asterisk installation.

Native PBX call/recording APIs and actual telephony/carrier acceptance remain
separate features. Their unfinished state does not require retaining obsolete
Dev tables, old services or a settings compatibility switch.

## Schema migrations

`../EchoDatabase/init` is mounted into the database container at
`/docker-entrypoint-initdb.d`, which MySQL runs **only when initialising an
empty data directory**. Files added after the first `up` are silently skipped —
which is how `009_settings.sql` sat in the repo while a running database had no
`echo_tbl_Settings`.

So a one-shot `echo-migrate` service applies the same files, in order, against
the database as it actually is, recording each in `echo_tbl_SchemaMigration`.
`echo-service` and `echo-web` wait on it completing.

The numbered application files run once under the ledger. Do not blindly replay
all current initialization files against an existing database. The retirement
migration itself is idempotent and removes only its explicit obsolete object
list. Fresh installations do not recreate the retired auth/settings tables.

## First install

```bash
scripts/install.sh          # writes protected .env once; does not start services
# Fill in NocoDB URL and both service tokens in .env.
# Prepare PlatformConfig rows and follow the deployment sequence above.
docker compose config --quiet
docker compose up -d --build
```

The installer generates MySQL bootstrap passwords for a fresh volume only. It
never overwrites an existing `.env`, initializes containers or rotates an existing
database password. Supply credentials matching the current database, or deliberately reset that
Dev store; changing a password in Compose alone does not change MySQL grants.

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
