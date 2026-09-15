# Deploying the UISP SSO / identity release to production

> **⚠ Out of date — verify before following.**
> This guide predates the Identity cutover. EchoWeb no longer owns provider
> OAuth: `/auth/google` and `/auth/microsoft` are now bare redirects to
> `/auth/identity`, and `GOOGLE_CLIENT_ID`, `UISP_BASE_URL`,
> `UISP_CRM_APP_KEY_READ` and `MICROSOFT_CLIENT_ID` no longer appear in EchoWeb's
> source at all. The settings table below also uses the retired
> `echo_tbl_Settings` shape (`sApp`/`sKey`, scope `web`) rather than
> PlatformConfig `cfg_tbl_Setting` scoped `*` -> `echo` -> `echo-web`.
> Hostnames have been genericized to `X.TLD`; the content has not been
> re-verified.

Runbook for taking the auth work from dev (`echo.localsplash.dev`) to
production (`echo.X.TLD`). Written to be followed top to bottom by someone —
or some agent — who was not part of building it.

**Read this first:** the login mechanism changes completely. The old
`businessNumber` cookie stops working, so **every currently logged-in user is
signed out** and must come back through the UISP client zone or Google. Do this
in a maintenance window, and make sure someone with an `@X.TLD` Google
account is available — that is the only way into the admin view if something
needs inspecting.

Both environments talk to the **same UISP instance** (`my.UISP.TLD`). Prod and
dev therefore share the CRM data but must **not** share the SSO secret.

---

## 0. Preconditions

- [ ] `https://echo.X.TLD` terminates TLS. The session cookie is `Secure`;
      over plain HTTP nothing will log in and the failure looks like a redirect loop.
- [ ] You can reach the prod host, its Docker stack, and its MySQL.
- [ ] You have an `@X.TLD` Google account (this becomes a super-admin).
- [ ] You can log in to `my.UISP.TLD` as a UISP administrator.
- [ ] You have the Google Cloud Console project for the OAuth client.

---

## 1. Take a database backup

Non-negotiable — step 4 alters existing tables.

```bash
docker exec echo-database sh -c \
  'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines echo_db' \
  > ~/echo_db-pre-auth-$(date +%F-%H%M).sql

ls -lh ~/echo_db-pre-auth-*.sql   # confirm it is non-empty before continuing
```

---

## 2. Generate a production SSO secret

Do **not** reuse the dev value. Anyone holding it can mint a valid assertion for
any CRM client.

```bash
openssl rand -hex 32
```

Keep the output; it goes in two places that must match exactly — prod `.env`
(step 3) and the UISP plugin config (step 6).

---

## 3. Google Cloud Console

In the OAuth 2.0 Client, add the production entries alongside the dev ones:

**Authorized JavaScript origins**
```
https://echo.X.TLD
```

**Authorized redirect URIs**
```
https://echo.X.TLD/auth/google/callback
```

The redirect URI must match `APP_BASE_URL + /auth/google/callback` character for
character — a trailing slash or `http` will fail with `redirect_uri_mismatch`.

> Rotate the client secret if the dev value has been shared around; it is set in
> `.env` below.

---

## 4. Pull code and apply migrations

```bash
cd /opt/echo/EchoDatabase   && git checkout main   && git pull
cd /opt/echo/EchoWeb        && git checkout main   && git pull
cd /opt/echo/EchoOrchestrator && git checkout master && git pull
```

`EchoDatabase/init/` only runs automatically when the MySQL volume is created,
so on an existing database apply the three migrations by hand:

```bash
cd /opt/echo/EchoDatabase
for f in init/005_auth.sql init/006_uisp_identity.sql init/007_identity_email.sql; do
  echo "-- $f"
  docker exec -i echo-database sh -c \
    'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" echo_db' < "$f" || echo "FAILED: $f"
done
```

Verify all six tables exist and the enum took:

```bash
docker exec echo-database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" echo_db -e "
  SELECT TABLE_NAME FROM information_schema.TABLES
   WHERE TABLE_SCHEMA=\"echo_db\" AND TABLE_NAME LIKE \"auth_%\";
  SELECT COLUMN_TYPE FROM information_schema.COLUMNS
   WHERE TABLE_SCHEMA=\"echo_db\" AND TABLE_NAME=\"auth_tbl_Identity\"
     AND COLUMN_NAME=\"provider\";"'
```

Expect the six `auth_tbl_*` tables and `enum('google','magic_link','uisp')`.

> Microsoft sign-in was added later and appends `'microsoft'` to that enum via
> `init/008_microsoft_identity.sql`. If you are deploying both releases at once,
> apply 008 as well and expect the four-value enum. See `DEPLOY-MICROSOFT-SSO.md`.

> If `docker exec` output comes back empty on your host, write the result to a
> file inside the container and `docker cp` it out — some sandboxes swallow
> `docker exec` stdout.

---

## 5. Production settings

These are **not** environment variables any more. They are rows in
`echo_tbl_Settings` in the Echo database, which each Echo app reads for
itself (EchoDatabase `init/009_settings.sql`). The `.env` on the host carries
only the MySQL credentials, and the NocoDB coordinates for `trustedCIDR`.

Set them with any MySQL client against `echo_db`:

```sql
UPDATE echo_tbl_Settings SET sValue = ? WHERE sApp = ? AND sKey = ?;
```

| `sApp` | `sKey` | Value |
| --- | --- | --- |
| `web` | `APP_BASE_URL` | `https://echo.X.TLD` |
| `web` | `GOOGLE_CLIENT_ID` | from Google Cloud Console |
| `web` | `GOOGLE_CLIENT_SECRET` | from Google Cloud Console |
| `web` | `UISP_SSO_SECRET` | the value generated in step 2 |
| `web` | `UISP_PLUGIN_URL` | filled in at step 7, after the plugin is installed |
| `*` | `UISP_BASE_URL` | `https://my.UISP.TLD` |
| `*` | `UISP_CRM_APP_KEY_READ` | read-only CRM App Key |

Use a **read-only** CRM App Key. Echo only reads clients; a read-write key here
widens the blast radius for no benefit.

`trustedCIDR` is the exception: it is platform-wide network policy, so it
lives in the NocoDB base `IdentityBase`, table `auth_tbl_Settings`, where
identity and every application read the same value.

A change in either place reaches every running service within 30 seconds — no
restart, no redeploy. Sanity-check `APP_BASE_URL` before starting: it must be
the prod host, not dev.

```bash
# The host .env should now contain only these.
grep -E 'MYSQL_|NOCODB_' /opt/echo/EchoOrchestrator/.env
```

---

## 6. Install the UISP plugin

Build the ZIP (the artifact is gitignored, so always rebuild rather than reusing
an old copy):

```bash
cd /opt/echo/EchoOrchestrator/uisp-plugin
zip -r echo-sso-plugin.zip manifest.json main.php public.php public/
```

Then in UISP as an administrator:

1. **CRM → System → Plugins → Add plugin**, upload the ZIP.
2. Configure it:
   - **Echo Base URL** — `https://echo.X.TLD` (no trailing slash)
   - **SSO Shared Secret** — the step 2 value, matching `.env` exactly
3. **Enable** the plugin.

> The dev and prod plugins point at different Echo URLs but there is only **one**
> UISP instance. If a single plugin instance is shared, its Echo Base URL decides
> which environment client-zone users land in. Point it at production once you cut
> over, and drive dev sign-ins by visiting the dev URL directly.

> `information.version` uses `YYYY.M.D`. Bump it on every re-upload or UCRM may
> treat the upload as a no-op and silently keep the old code.

---

## 7. Copy the generated plugin URL back to Echo

UCRM generates the public URL itself; it is not a path you can predict.

1. On the plugin page, copy **Plugin public URL**.
2. Put it in `.env` as `UISP_PLUGIN_URL`.
3. Restart (step 8).

Until this is set, the UISP button ("Continue with Wisp.net") stays hidden on the
login page — by design, rather than linking somewhere broken.

> If that field is blank in UCRM, set **Server domain name** / **Server IP**
> under CRM → System → Settings. UCRM cannot generate the URL without one.

---

## 8. Deploy

```bash
cd /opt/echo/EchoOrchestrator
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
docker compose ps
curl -sS https://echo.X.TLD/healthz
```

Expect `{"ok":true,"service":"EchoWeb"}`.

---

## 9. Verify

Confirm config reached the browser (the plugin URL should be populated):

```bash
curl -sS https://echo.X.TLD/config.js
```

Then walk the paths:

- [ ] **Super-admin** — sign in with an `@X.TLD` Google account. Lands on
      `/internal`. Enter a known business number → messages load.
- [ ] **Admin view** — `/internal/accounts` lists orgs, users and identities.
- [ ] **UISP bridge** — from a CRM client with a `hostedPulseNumber`, click
      **Echo Messages** in the client zone → lands in Echo signed in.
- [ ] **Auto-return** — signed out of UISP, click the ISP button on Echo's login
      page → UISP login → returns to Echo automatically without a manual click.
- [ ] **No number** — a client without a `hostedPulseNumber` sees the no-access page.
- [ ] **Google return login** — sign in with a linked Google account → straight in.
- [ ] **Unknown Google address** — an address not on any CRM contact → `/sign-up`.

Optional automated pass (mutates data — use a scratch CRM client, not a live one):

```bash
set -a; . /opt/echo/EchoOrchestrator/.env; set +a
cd /opt/echo/EchoWeb/scripts/manual-tests
ECHO_BASE_URL=https://echo.X.TLD node identity.js
ECHO_BASE_URL=https://echo.X.TLD node crm-match.js
```

---

## 10. Tell users

Everyone is signed out. Expect support contacts. The message is:

> Echo now signs you in through your ISP account or Google — the phone-number
> box is gone. Go to `echo.X.TLD` and choose **Sign in with your ISP account**,
> or click **Echo Messages** in the my.UISP.TLD client zone.

---

## Rollback

Code first, data last:

```bash
cd /opt/echo/EchoWeb          && git checkout <previous-commit>
cd /opt/echo/EchoOrchestrator && git checkout <previous-commit>
cd /opt/echo/EchoOrchestrator && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Also **disable the UISP plugin**, or client-zone users will be redirected into an
Echo that no longer understands the assertion.

The `auth_tbl_*` tables are additive and can be left in place — the old code
ignores them. Only restore the step 1 dump if you need to undo the `007` `ALTER`
on `auth_tbl_Identity`, and be aware that restoring also rolls back any messages
received since the backup.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `redirect_uri_mismatch` from Google | `APP_BASE_URL` doesn't match the Console redirect URI exactly |
| Login appears to succeed then bounces to the login page | Not served over HTTPS — the `Secure` cookie is dropped |
| ISP button missing on the login page | `UISP_PLUGIN_URL` empty (step 7) |
| Plugin page shows "not configured" | `ssoSecret` or Echo Base URL blank in the plugin config |
| `?auth_error=invalid_sso_code` | `UISP_SSO_SECRET` differs from the plugin's secret |
| `?auth_error=sso_replay` | Code already redeemed — expected on refresh/back; retry from the client zone |
| `?auth_error=no_account` | CRM lookup failed. Check `UISP_CRM_APP_KEY_READ` and reachability of `my.UISP.TLD` |
| Client-zone login doesn't auto-return | `public/client-zone.js` not injected — check the client-zone page source for the script tag |
| Menu icon unstyled | UISP markup changed. Cosmetic only; the link still works |
| `docker exec` prints nothing | Sandbox swallowing stdout — redirect to a file inside the container and `docker cp` it out |

## After cutover

- Rotate the dev `UISP_SSO_SECRET` if prod ever briefly shared it.
- The `hostedPulseNumber` CRM attribute is what gates access. A client without
  one gets the no-access page, so set it before onboarding.
- Super-admin access is any `@X.TLD` Google account. That is the whole
  authorization check — treat control of that domain accordingly.
