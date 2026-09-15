# Deploying Microsoft (Entra ID) sign-in to production

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

> `isWispStaff`, which this guide cites in `EchoWeb/src/app.ts`, does not
> exist there any more — SUPER_ADMIN now comes only from the verified
> central session flag.

Runbook for adding Microsoft as a third login provider on
`echo.X.TLD`, alongside the Google and UISP paths that are already live.

This is a **delta on top of the auth release** (see `DEPLOY-AUTH.md`), which is
already deployed to production. It is far smaller than that one, and in two
important ways safer:

- **Nobody is signed out.** Sessions, the session cookie and every existing
  identity are untouched. This release only adds a new way in.
- **The kill switch is an env var, not a rollback.** The login page hides the
  Microsoft button unless `MICROSOFT_CLIENT_ID` is set, so blanking one
  variable and restarting fully disables the feature without reverting code.

Expect ~10 minutes, and it does not need a maintenance window.

---

## 0. Preconditions

- [ ] The auth release is live on `echo.X.TLD` (confirm: `curl -sS
      https://echo.X.TLD/config.js` returns a populated `UISP_PLUGIN_URL`).
- [ ] You are an owner of the Entra app registration in the Wisp directory.
- [ ] You can reach the prod host, its Docker stack, and its MySQL.

---

## 1. Back up the database

Step 3 alters `auth_tbl_Identity`.

```bash
docker exec echo-database sh -c \
  'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines echo_db' \
  > ~/echo_db-pre-microsoft-$(date +%F-%H%M).sql

ls -lh ~/echo_db-pre-microsoft-*.sql   # confirm non-empty before continuing
```

---

## 2. Entra app registration

In **Microsoft Entra admin center → App registrations → the Echo app**:

**Authentication → Redirect URIs (Web)** — add the production callback
alongside the dev one:

```
https://echo.X.TLD/auth/microsoft/callback
```

It must equal `APP_BASE_URL + /auth/microsoft/callback` character for
character. A trailing slash or `http` fails with `AADSTS50011`.

**Authentication → Supported account types** must be **"Accounts in any
organizational directory and personal Microsoft accounts"**. Echo uses the
`common` authority so that subscribers can sign in with their own M365 or
Outlook accounts, mirroring how Google accepts any Google account. A
single-tenant registration fails at sign-in with `AADSTS50194`.

> **These two settings cannot be verified from outside.** The authorize
> endpoint renders the sign-in page even for a bogus client ID and an
> unregistered redirect URI — all validation is deferred until after the user
> authenticates. Confirm them in the portal; a green-looking `curl` proves
> nothing.

**Certificates & secrets** — issue a **fresh client secret for production**.
The value used on dev was shared in plaintext during development and should be
treated as compromised. Copy the **Value** (not the Secret ID) immediately; it
is only shown once. Note its expiry and put a calendar reminder in — an expired
secret breaks sign-in with `AADSTS7000222` and the failure looks like a
generic token exchange error.

No API permissions or admin consent are needed: Echo requests only
`openid profile email`, and reads the profile from the `id_token`.

---

## 3. Pull code and apply migration 008

```bash
cd /opt/echo/EchoDatabase     && git checkout main   && git pull
cd /opt/echo/EchoWeb          && git checkout main   && git pull
cd /opt/echo/EchoOrchestrator && git checkout master && git pull
```

`EchoDatabase/init/` only runs automatically when the MySQL volume is created,
so apply the new migration by hand:

```bash
cd /opt/echo/EchoDatabase
docker exec -i echo-database sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" echo_db' < init/008_microsoft_identity.sql
```

Verify the enum took:

```bash
docker exec echo-database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" echo_db -e "
  SELECT COLUMN_TYPE FROM information_schema.COLUMNS
   WHERE TABLE_SCHEMA=\"echo_db\" AND TABLE_NAME=\"auth_tbl_Identity\"
     AND COLUMN_NAME=\"provider\";"'
```

Expect `enum('google','magic_link','uisp','microsoft')`.

> If `docker exec` prints nothing on your host, assert via exit code instead:
> ```bash
> docker exec echo-database sh -c "test \$(mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -D echo_db \
>   -e \"SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='echo_db' \
>   AND TABLE_NAME='auth_tbl_Identity' AND COLUMN_TYPE LIKE '%microsoft%'\") -eq 1" \
>   && echo "migration applied"
> ```

The migration is additive. Older code ignores the new enum value, so it does
not need to be reverted if you roll the app back.

---

## 4. Production `.env`

Add to `/opt/echo/EchoOrchestrator/.env`:

```ini
# Microsoft / Entra ID OAuth
MICROSOFT_CLIENT_ID=d534cd2e-b476-4ce3-bbf4-898d2402e724
MICROSOFT_CLIENT_SECRET=<the NEW production secret Value from step 2>
MICROSOFT_TENANT=common
```

| Variable | Purpose | If unset |
|---|---|---|
| `MICROSOFT_CLIENT_ID` | Application (client) ID. Also the feature flag — the login button is hidden while it is empty. | Microsoft sign-in is off; everything else unaffected |
| `MICROSOFT_CLIENT_SECRET` | Client secret **Value**. Used only server-side for the token exchange. | Sign-in starts, then fails at token exchange |
| `MICROSOFT_TENANT` | Authority segment. `common` = any work/school or personal account. A directory GUID restricts sign-in to that tenant alone. | Defaults to `common` |

Two values from the Entra portal are deliberately **not** used and should not be
added: the **Object ID** (a Graph management identifier) and the **Secret ID**
(the identifier *of* the secret, not the secret itself).

Sanity-check before restarting:

```bash
grep -E 'APP_BASE_URL|MICROSOFT_' /opt/echo/EchoOrchestrator/.env
```

`APP_BASE_URL` must be `https://echo.X.TLD`, or the redirect URI Echo sends
will not match what you registered in step 2.

### Super-admin stays on Google

Microsoft **cannot** grant super-admin, by design. Super-admin is granted on an
`@X.TLD` address, and Google is the only provider trusted to assert one — it
verifies the Workspace domain it reports. Entra does not: with a `common`
authority the address is whatever the user's own tenant put there, so any
directory on earth could mint an `@X.TLD` user. X.TLD is a Google
Workspace domain and staff stay on Google, so Microsoft never reaches that
branch (`isWispStaff` in `EchoWeb/src/app.ts`).

An X.TLD person who signs in with Microsoft is treated as an ordinary user
and, having no membership, is turned away with `?auth_error=no_membership`.
That is expected — tell staff to use **Continue with Google**.

The customer-facing path is deliberately looser and matches Google: a CRM
contact email match provisions an org owner. That is an accepted risk — a
malicious M365 tenant admin could claim a subscriber's org by setting a user's
email to their contact address. Revisit by requiring the `xms_edov` optional
claim if orgs ever need stricter control.

---

## 5. Deploy

```bash
cd /opt/echo/EchoOrchestrator
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
docker compose ps
curl -sS https://echo.X.TLD/healthz
```

Expect `{"ok":true,"service":"EchoWeb"}`.

---

## 6. Verify

Confirm the flag reached the browser:

```bash
curl -sS https://echo.X.TLD/config.js
```

Expect `"MICROSOFT_ENABLED":true` alongside the existing keys.

Confirm the authorize redirect is well-formed:

```bash
curl -sS -D - -o /dev/null https://echo.X.TLD/auth/microsoft | grep -i '^location'
```

The `redirect_uri` in that URL must be
`https%3A%2F%2Fecho.X.TLD%2Fauth%2Fmicrosoft%2Fcallback`.

Then walk the paths in a browser:

- [ ] **Branding** — login page shows **Continue with Google**, **Continue with
      Microsoft**, **Continue with Wisp.net**, the new Echo mark, and the
      favicon in the tab.
- [ ] **New Microsoft user** — sign in with a Microsoft account whose address is
      a CRM contact with a `hostedPulseNumber` → lands in Echo, messages load.
- [ ] **Unknown Microsoft address** — not on any CRM contact → `/sign-up`.
- [ ] **Return login** — sign out, sign in again with the same account →
      straight in, no duplicate org created (check `/internal/accounts`).
- [ ] **Linking** — from **Settings → Sign-in Methods → Link Microsoft**, attach
      a Microsoft account to an existing user, sign out, sign back in with it.
- [ ] **Super-admin unaffected** — an `@X.TLD` **Google** account still lands
      on `/internal`. Microsoft cannot grant super-admin; that is intentional.
- [ ] **No regressions** — Google sign-in and the UISP client-zone bridge still
      work. Both share the refactored callback, so give each one pass.

---

## Rollback

Fastest, and almost always enough — blank the client id and restart:

```bash
sed -i 's/^MICROSOFT_CLIENT_ID=.*/MICROSOFT_CLIENT_ID=/' /opt/echo/EchoOrchestrator/.env
cd /opt/echo/EchoOrchestrator
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

The button disappears, `/auth/microsoft` redirects to
`/?auth_error=microsoft_not_configured`, and Google/UISP are unaffected.

Full code rollback, if the shared-callback refactor turns out to be at fault:

```bash
cd /opt/echo/EchoWeb          && git checkout <previous-commit>
cd /opt/echo/EchoOrchestrator && git checkout <previous-commit>
cd /opt/echo/EchoOrchestrator
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Leave migration 008 in place — it is additive and the old code ignores it.
Restoring the step 1 dump is only necessary if you must undo the `ALTER`, and it
would also roll back any messages received since the backup.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Microsoft button missing on the login page | `MICROSOFT_CLIENT_ID` empty, or the container wasn't restarted after editing `.env` |
| `AADSTS50011` redirect URI mismatch | Prod callback not registered, or `APP_BASE_URL` isn't `https://echo.X.TLD` |
| `AADSTS50194` application not multi-tenant | Supported account types is single-tenant; `MICROSOFT_TENANT=common` requires multitenant + personal |
| `AADSTS7000215` invalid client secret | The **Secret ID** was pasted instead of the **Value** |
| `AADSTS7000222` client secret expired | Issue a new secret in Entra and update `.env` |
| `?auth_error=token_exchange_failed` | Secret wrong/expired, or the prod host cannot reach `login.microsoftonline.com` |
| `?auth_error=userinfo_failed` | The `id_token` carried no usable address — the account has neither an `email` nor an email-shaped `preferred_username` |
| `?auth_error=invalid_state` | Session expired mid-login, or the state cookie was minted for the other provider; retry |
| `@X.TLD` account signing in with Microsoft gets `no_membership` | Expected — super-admin is Google-only. Use **Continue with Google** |
| `?auth_error=no_account` | CRM lookup threw. Check `UISP_CRM_APP_KEY_READ` and reachability of `my.UISP.TLD` |
| Duplicate org appears for an existing subscriber | The CRM client had no prior org and the address matched a different client — inspect via `/internal/accounts` |

## After cutover

- Rotate the **dev** `MICROSOFT_CLIENT_SECRET` too; the original value was shared
  in plaintext during development.
- Record the production secret's expiry date. Entra secrets are time-limited and
  the failure mode is a total outage of Microsoft sign-in.
- Microsoft identities are removable by users in Settings, unlike the UISP
  binding — but Echo still refuses to remove anyone's *last* sign-in method.
