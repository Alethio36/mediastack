# Adding email (SMTP)

The portal (authentik) can send email. It is optional: without it nothing
breaks, and someone locked out gets a sign-in link from
`./mediastack.sh reset-password <user>` instead. With it, the portal has a
working outgoing mail path you can test — the base later features (password
reset by email) need.

mediastack speaks plain **SMTP**, so any provider works. You need six things
from yours:

| Setting | What it is | Typical |
|---|---|---|
| Server | the provider's SMTP host | `smtp.gmail.com` |
| Security | how the connection is encrypted | STARTTLS |
| Port | goes with the security | 587 (STARTTLS), 465 (TLS) |
| Login | your account at the server | often your full email address |
| Password | **an app password or SMTP key** — not your normal password | `abcdefghijklmnop` |
| Send as | the From address | one the login may send from |

## 1. Pick a sender

### A. A mailbox you already have (simplest)

Mail goes out as you, through your provider. Good for a household: nothing
to set up in DNS, and the provider's reputation gets it delivered.

* **Gmail** — server `smtp.gmail.com`, STARTTLS on 587. Login: your Gmail
  address. Password: an **app password** (2-Step Verification must be on;
  then https://myaccount.google.com/apppasswords). Google shows it as four
  groups of four letters — **type it without the spaces**. Send as: your
  Gmail address (or an alias you have added in Gmail). A Google Workspace
  account may have app passwords turned off by its admin.
* **Fastmail** — server `smtp.fastmail.com`, TLS on 465 (or STARTTLS on
  587). Login: your Fastmail address. Password: an **app password** created
  in Fastmail's settings (Privacy & Security) with SMTP access.
* **Anyone else** — search your provider's help for "SMTP settings" and
  "app password". Some providers no longer allow a plain password for SMTP
  at all; if yours offers only "OAuth" or "modern authentication", use B.

### B. A sending service

Built for apps sending mail: a free tier is plenty for a household. You
verify a domain you own (they give you DNS records to add), then send from
any address on it.

* **Brevo** — server `smtp-relay.brevo.com`, STARTTLS on 587. Login and
  password: the **SMTP login and SMTP key** from its dashboard (not your
  account password).
* **Mailgun** — server `smtp.mailgun.org`, STARTTLS on 587. Login and
  password: the domain's **SMTP credentials** (Domain settings).
* **Amazon SES** — server `email-smtp.<region>.amazonaws.com`, STARTTLS on
  587. Login and password: **SMTP credentials** created in SES (not your AWS
  access keys).

### C. A relay on your own domain or LAN

A mail server you run, or a relay on your router or NAS. Use its host and
port; leave the login empty if it takes none. **Security "none" sends the
login and every message readable** — only for a relay on this machine or
your LAN.

## 2. Your own domain: SPF and DKIM

Sending **from your own domain** (`portal@yourdomain.com`) through a service
(B) or your relay (C)? Receiving servers check that the sender is allowed:

* **SPF** — a TXT record listing who may send for the domain.
* **DKIM** — a signing key the sender uses, published as a DNS record.
* **DMARC** — a TXT record saying what to do with mail that fails both.

The service gives you the exact records; add them at your DNS host. Until
they are in place, test messages land in spam or bounce. Sending from your
own mailbox (A) needs none of this.

## 3. Set it up

```bash
./mediastack.sh configure          # the "Email (optional)" step near the end
./mediastack.sh up                 # authentik reads the settings when it starts
./mediastack.sh email test you@example.com
```

`configure` asks for the server, security, port, login, password (hidden)
and the send-as address; run it again to keep, change or remove them.
`email test` sends a real message through authentik itself, so a pass means
the portal's own mail works. `email status` shows the settings and whether
they have passed a test; `doctor` reports the same.

**The password may not contain `$` or spaces** — compose would rewrite it.
App passwords and SMTP keys never do; `configure` refuses one that does.

## 4. Troubleshooting

`email test` prints the server's own words, then what that usually means:

| The server says | Usually | Fix |
|---|---|---|
| `535`, "Authentication", "Username and Password not accepted" | the login was refused | an **app password** / SMTP key, not your normal password; check the login |
| "wrong version number", SSL/TLS errors | security does not match the port | 587 → STARTTLS, 465 → TLS |
| "timed out", "connection refused", "unreachable" | the server was not reached | check the server name and port; many home connections **block port 25** outbound — use 587 or 465 |
| `550`/`553`/`554`, "sender rejected", "not owned" | the From address is not allowed | send as your mailbox address, or verify the domain with the service |
| "older email settings" (from mediastack) | authentik still runs the previous settings | `./mediastack.sh up`, then test again |

The test arrived but in spam: your domain needs SPF/DKIM (section 2), or send
as your mailbox (A).

## Turning it off

`./mediastack.sh configure` → Email → `r` (remove), then `./mediastack.sh up`.
