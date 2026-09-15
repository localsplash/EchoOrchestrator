# Echo SSO Bridge — UISP Plugin

Converts an authenticated UISP client-zone session into a short-lived signed code that Echo redeems to log the client in.

## Package layout

UCRM requires these files **at the root of the ZIP** (not nested in a folder):

```
manifest.json           plugin metadata + config fields (must be named manifest.json)
main.php                required by UCRM; no-op for this plugin
public.php              the SSO entry point
public/client-zone.js   auto-loaded by UCRM on every client zone page
```

Rebuild the ZIP with:

```bash
cd /opt/echo/EchoOrchestrator/uisp-plugin
zip -r echo-sso-plugin.zip manifest.json main.php public.php public/
```

## How the round trip works

Starting from Echo while not yet signed in to UISP used to dead-end: the CRM
login form has no target-path field, and `public.php` sits outside the Symfony
firewall, so UISP never learns where the user came from and always drops them
on the client zone.

`public/client-zone.js` closes that gap. UCRM loads it on every client zone page
(UISP 1.1.0-beta2+), so:

1. Echo → `public.php`, no CRM session.
2. `public.php` sets a short-lived `echo_sso_intent` cookie and redirects to `/crm/login`.
3. User signs in; UISP lands them on the client zone.
4. `client-zone.js` sees the cookie, clears it, and forwards back to `public.php`.
5. `public.php` now has a session → signs the code → redirects to Echo.

The cookie is host-only, JS-readable (the script must read it), expires in 5
minutes, and is cleared *before* the redirect — so a downstream failure cannot
produce a loop. The script also refuses to navigate anywhere off-origin.

If JavaScript is unavailable the user simply stays in the client zone, where the
**Echo Messages** menu item still works.

## The menu item

`manifest.json` registers a client-zone link (`type: client`, `target: blank`).
Two constraints are worth knowing:

- A menu item can only point at the plugin's own `public.php` — never an
  arbitrary external URL. This is the better behaviour anyway: `public.php`
  mints the SSO code and forwards to the Echo Base URL, so the user arrives
  already signed in. A direct link would land them on Echo's login page.
- `target` is `blank`, not `iframe`, deliberately. Echo's session cookie is
  `SameSite=Lax`, so in a cross-site iframe the browser would withhold it and
  sign-in would fail.

### Icon

UCRM's manifest has no icon field, so `client-zone.js` swaps the icon in the DOM
after load. It finds the link by href (falling back to the `Echo Messages`
label, which is less robust — labels change with locale), replaces the existing
icon node, and reuses that node's CSS classes so UISP's own sizing still
applies.

The idle icon uses `fill="currentColor"` so it inherits whatever colour UISP
gives menu links, including hover and active transitions. When the item is
marked active it switches to the `#E5F0FF` / `#006FFF` treatment.

This is cosmetic and deliberately fail-quiet: every step is guarded, and if
UISP changes its markup the icon simply stops being applied — the link keeps
working. See `tests/` for the DOM test suite.

## Versioning

`information.version` uses `YYYY.M.D`. The top-level `"version": "1"` is the
manifest *schema* version and must stay `1`. Bump `information.version` on every
upload; UCRM needs a version change to accept a re-upload as an update.

## Installing

There is **no plugin API in UCRM 4.5.33** — every `/crm/api/v1.0/plugins` route returns 404. Installation is manual through the admin UI:

1. Log in to `https://my.UISP.TLD` as a UISP administrator.
2. Go to **CRM → System → Plugins**.
3. Click **Add plugin** (`+`) and upload `echo-sso-plugin.zip`.
4. Open the plugin and fill in its two config fields:
   - **Echo Base URL** — `https://echo.X.TLD` — see "Deployed instances" in the repository README for the value per environment
   - **SSO Shared Secret** — must match `UISP_SSO_SECRET` in Echo's environment
5. **Enable** the plugin.

## After installing: copy the public URL back to Echo

UCRM generates the plugin's public URL itself and displays it on the plugin page as **"Plugin public URL"**. It is not a path you can predict, so Echo takes it as configuration:

1. Copy the "Plugin public URL" value from the UISP plugin page.
2. Set it as `UISP_PLUGIN_URL` in `/opt/echo/EchoOrchestrator/.env`.
3. `./scripts/rebuild.sh echo-web`

Until `UISP_PLUGIN_URL` is set, the "Sign in with your ISP account" button stays hidden on Echo's login page rather than linking somewhere broken.

> If the plugin page shows the public URL as empty, UCRM has no **Server domain name** / **Server IP** configured under CRM → System → Settings. The public URL cannot be generated without it.

## Switching dev → prod

Change **Echo Base URL** in the plugin config to the target environment's `https://echo.X.TLD` and update `UISP_PLUGIN_URL` on the prod Echo host. Nothing else changes — both environments talk to the same UISP instance.

## Security

- The SSO secret must match `UISP_SSO_SECRET` in Echo's environment exactly.
- Signed codes expire after 30 seconds and are single-use (replay-protected by `auth_tbl_SsoNonce`).
- The plugin only reads the UISP session; it never writes to UISP.
