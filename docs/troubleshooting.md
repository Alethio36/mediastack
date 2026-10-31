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
