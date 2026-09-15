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

Hostnames below are written against `X.TLD`, the whitelabel parent domain a
deployment serves under. Substitute it throughout. The values in use today are
recorded in [Deployed instances](#deployed-instances).

At the edge host, the canonical model is:

- **Nginx Proxy Manager/openresty** owns the public Echo hostnames and TLS termination
- **EchoOrchestrator** runs the containers on the shared `echo-net` Docker network so NPM can proxy directly to service names
- Localhost-only published ports remain useful for direct service checks and fallback/debugging

## Hostname mapping

- `echo.X.TLD` → NPM/openresty → `echo-web:3160`
- `webhook.echo.X.TLD` → NPM/openresty → `echo-service:8080`

Two public hostnames, not three. Each names the surface it exposes rather than
the repository behind it:

- `echo.X.TLD` is the application. EchoService's API reaches browsers through
  EchoWeb's `/api/*` routes over the internal network, so EchoService needs no
  public name of its own for that traffic.
- `webhook.echo.X.TLD` exists only for carrier ingress — see
  [Carrier webhook endpoints](#carrier-webhook-endpoints). It replaces the
  former `io.echo.X.TLD`, which named the repo rather than its one public
  surface.
- **EchoMedia has no public hostname.** Attachments are served through EchoWeb's
  session-gated same-origin `/media` route, which rechecks membership and
  stored-path ownership on every request. The former `media.echo.X.TLD` proxy
  host should be retired: neither carrier ever fetches from it (Bandwidth
  uploads to its own media store and hands back a `messaging.bandwidth.com`
  URL; Tychron sends bytes inline), so after the EchoWeb cutover it serves
  nobody.

## Carrier webhook endpoints

These are the URLs to configure in the Bandwidth and Tychron consoles. All four
are `POST`, all are served by EchoService, and all live under
`webhook.echo.X.TLD` — no other EchoService endpoint is publicly reachable.

| Provider | Method | Path |
| --- | --- | --- |
| Bandwidth | `POST` | `/webhooks/bandwidth/inbound` |
| Bandwidth | `POST` | `/webhooks/bandwidth/status` |
| Tychron | `POST` | `/webhooks/tychron/sms` |
| Tychron | `POST` | `/webhooks/tychron/mms` |

Full URLs:

```
https://webhook.echo.X.TLD/webhooks/bandwidth/inbound
https://webhook.echo.X.TLD/webhooks/bandwidth/status
https://webhook.echo.X.TLD/webhooks/tychron/sms
https://webhook.echo.X.TLD/webhooks/tychron/mms
```

### Authentication

A caller whose address falls inside the platform-wide `trustedCIDR` is allowed
through without credentials. Everyone else must present HTTP Basic using the
`WEBHOOK_BASIC_USER` and `WEBHOOK_BASIC_PASS` settings. Bandwidth reaches Echo
from outside the trusted network, so basic auth is the real path for it; a
same-host Tychron relay may fall inside the CIDR instead.

`trustedCIDR` is a single platform-wide value in the NocoDB base `IdentityBase`,
table `auth_tbl_Settings`. identity owns and writes it; EchoService only reads
it. Enforce the same value at the NPM/openresty edge.

**The client address must resolve through the proxy, not the socket peer.** This
is not a style preference. Behind Nginx Proxy Manager every request arrives from
the proxy's own address on the Docker network, which falls inside the
`172.16.0.0/12` entry of `trustedCIDR` — so the peer check passed for *every*
caller and basic auth was not enforced at all. An unauthenticated
`curl -X POST https://<host>/webhooks/tychron/sms` answered 204 and could write
fabricated inbound messages straight into the database.

### Body size

The edge must allow 10 MB (`client_max_body_size 10m`), matching EchoService's
own `express.json` limit. Tychron carries MMS media inline as base64, which adds
about a third to a file whose per-item ceiling is already 2 MB, so nginx's 1 MB
default would `413` an ordinary photo. Tychron treats any non-2xx as a temporary
failure and redelivers indefinitely, so an undersized limit does not drop one
message — it starts a redelivery loop.

### Cutover

Re-registering these URLs in the carrier consoles is an external step, and it is
the only genuinely risky part of a hostname change — no repository change can do
it. Point the carriers at the new host, then confirm inbound SMS *and* MMS
arrive end to end before deleting the old one. Verify both: MMS exercises the
10 MB body path that SMS never touches, so an undersized limit passes an
SMS-only check and then fails on the first photo.

## Deployed instances

Every document here is written against `X.TLD`. This is the one place concrete
values are recorded. Each environment is an independent parent domain — the
scheme is what they share, not the domain.

### dev — `localsplash.dev`

| | Value |
| --- | --- |
| `PARENT_DOMAIN` | `localsplash.dev` |
| Application | `echo.localsplash.dev` |
| Carrier ingress | `webhook.echo.localsplash.dev` — not yet created |

Changes land here first. It already fits the scheme: `echo.localsplash.dev` is
`echo.X.TLD` with `X.TLD` = `localsplash.dev`. It lacks only a `webhook.` host,
having no carrier registration of its own. The former `dev-echo.localsplash.ai`
name is retired.

### production — `wisp.net`

| | Value |
| --- | --- |
| `PARENT_DOMAIN` | `wisp.net` |
| Edge host | `proxy.wisp.net` |
| Application | `echo.wisp.net` → cert `npm-9` |
| Carrier ingress | `webhook.echo.wisp.net` → **new certificate required** |

Retired, or to be retired once the cutover completes:

| Hostname | Status |
| --- | --- |
| `io.echo.wisp.net` (cert `npm-11`) | superseded by `webhook.echo.wisp.net` |
| `media.echo.wisp.net` (cert `npm-12`) | retire the proxy host and certificate — EchoMedia is no longer publicly served |

### Adding an instance

Further production environments run on their own domains. Nothing in the code
or these documents needs changing for one — the scheme is the same and every
public URL derives from `PARENT_DOMAIN`. Per environment:

1. Set `PARENT_DOMAIN` in that deployment's PlatformConfig `echo` scope.
2. Point `echo.X.TLD` and `webhook.echo.X.TLD` at the edge host in DNS.
3. Create both NPM proxy hosts, issue a certificate for each (per-host certs,
   not a wildcard), and set `client_max_body_size 10m` on the webhook host.
4. Register the four carrier webhook URLs for that domain — see
   [Carrier webhook endpoints](#carrier-webhook-endpoints).
5. Leave the internal service addresses alone unless the Compose service names
   differ from the defaults. `ECHO_SERVICE_BASE_URL` and
   `MEDIA_INTERNAL_BASE_URL` are process environment defaulting to
   `http://echo-service:8080` and `http://echo-media:8082`. They are
   deliberately not settings rows — where a sibling container answers is
   Compose's to name, and a row could only drift from the file that assigns it.
6. Keep the localhost proxy-port pattern for direct service checks, and the
   external volume strategy if that environment needs durable database and
   media state.

Do not create a media hostname. EchoMedia is reached only through EchoWeb's
`/media` route.

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

Live NPM proxy-host records on the edge host are the source of truth for the
Echo edge. Each public hostname needs its own Let's Encrypt certificate — these
are per-host certs, not a wildcard, so `webhook.echo.X.TLD` requires a newly
issued one rather than an edit to an existing SAN list.

The files under `deploy/nginx/` are historical/fallback references only; do not treat them as the canonical production edge unless NPM is intentionally bypassed.

## PBX boundary

Identity owns business users/tenants and shared-number access. The installed
OfficePulse/Asterisk PBX owns extensions, queues and applied DID routes, accessed
through OfficePulseAidaIntegration's API. EchoOrchestrator does not deploy an
AidaAdmin-to-Asterisk synchronization worker or a separate AidaOfficePbxAdmin.
AidaAgent and AidaHandset are deferred. Deprecated AidaControl and the historical
AidaInfrastructureSetupInstructions repository are not deployment dependencies.
