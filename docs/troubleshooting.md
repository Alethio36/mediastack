# Troubleshooting

Problems that look like the stack is broken but aren't. Each entry: what you
see, why, and the fix.

## Android phone can't open the stack by its LAN address

**What you see.** On an Android phone on your home Wi-Fi, every browser fails
to open the stack by its LAN address (`http://192.168.x.x:5055`, a local-only
hostname, etc.) — "This site can't be reached", often
`ERR_TOO_MANY_RETRIES` — while desktops on the same network work fine. Apps
that use your public address (for example the Jellyfin app pointed at
`https://jellyfin.yourdomain`) keep working, which makes it look like a
network or stack fault. It usually starts out of nowhere, right after a phone
or browser update.

**Why.** Newer Android versions block apps from reaching devices on the local
network unless the app holds a permission. On Samsung and stock Android that
permission sits under **Nearby devices**. Browsers that never needed it
(it used to cover only Bluetooth and the like) are left denied, so their LAN
requests are dropped on the phone — they never reach your server.

**Fix.** On the phone, for each browser you use:

1. Settings → Apps → *the browser* → Permissions → **Nearby devices** → Allow.
2. Force-stop the browser (App info → Force stop) and reopen it.

Nothing on the server needs to change. Every Android phone in the household
needs this once per browser.

## After a Wizarr sign-up, the new person lands on another Jellyfin

**What you see.** Someone signs up through a Wizarr invitation, is sent on to
Jellyfin, and gets "invalid username or password" — on a Jellyfin that looks
different (another server's background, its login message), at an address
like `http://jellyfin:8096`.

**Why.** Wizarr sends a new person to its Jellyfin server's **External URL**.
Left empty, it uses the internal address the stack's containers talk on
(`http://jellyfin:8096`). Your browser is outside that network: your LAN's
DNS can complete `jellyfin` with its own search domain and open some other
Jellyfin, where the new account does not exist.

**Fix.** In Wizarr: Settings → Servers → edit the Jellyfin server → External
URL: the stack's Jellyfin address (`./mediastack.sh status` shows it,
`https://jellyfin.<your domain>` with HTTPS). `./mediastack.sh wire wizarr`
and doctor check it and name the address to set.

## Wizarr stops reaching Jellyfin after `rotate-secrets`

**What you see.** After a rotation, Wizarr's invitations fail or its
dashboard says it cannot reach Jellyfin.

**Why.** Wizarr holds its own copy of the stack's Jellyfin API key, which the
rotation replaced, and Wizarr's API cannot be given the new one — the
rotation's closing warning says so.

**Fix.** `./mediastack.sh credentials` shows the new Jellyfin API key; paste
it into Wizarr: Settings → Servers → edit the Jellyfin server → API key.
