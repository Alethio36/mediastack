# Certificates

Every service has its own HTTPS name under one domain
(`https://jellyfin.<domain>`, `https://portal.<domain>`, …), so the stack
serves one certificate covering the domain and its wildcard. `configure`
asks where it comes from; `./mediastack.sh traefik-setup --certs` switches
later.

| Choice | What you need | Renewal |
|---|---|---|
| **Let's Encrypt** (recommended) | the domain's DNS on Cloudflare, a Cloudflare API token (Zone / DNS / Edit, that zone only) and an email | automatic — Traefik renews it |
| **Your own** | two PEM files: the certificate with its chain, and its private key | yours: replace the files, run `up` |
| **Staging** | as Let's Encrypt | automatic — test certificates browsers warn about |

Let's Encrypt proves the domain is yours through DNS (DNS-01): nothing is
opened to the internet. Production allows 5 identical certificates a week,
so test installs use **staging**. Apps that check the portal's certificate
themselves refuse a staging one: Kavita's portal sign-in waits for a real
certificate (wire says so), Audiobookshelf's is expected to fail, and
Jellyfin's LDAP sign-in skips the check while it is staging.

## Your own certificate

`configure` (full mode) or `traefik-setup --certs`, answer **2**, then give
the two files' paths (Tab completes a path). Quick mode, and `enable
traefik`, take the recommended answer, Let's Encrypt — choose your own there
with `traefik-setup --certs` afterwards. They may live anywhere on the host; they must be
readable by you. The pair is checked when you give it and again on every
`up`, and refused — with the reason — unless:

- **the certificate file** is PEM, the leaf first and then its intermediates
  (a "fullchain" file);
- **the key** is PEM and **unencrypted** — Traefik cannot ask for a
  passphrase — and belongs to that certificate;
- it covers **both** `<domain>` and `*.<domain>`;
- it has **more than 7 days** left;
- it **chains to a public CA** (the host's bundle,
  `/etc/ssl/certs/ca-certificates.crt`). Kavita and Jellyfin check the
  portal's certificate inside their own containers, which trust only public
  CAs: a certificate from your own CA would break their sign-in quietly, so
  it is refused here instead.

`up` copies the pair into Traefik's folder (`config/traefik/certs/`, mode
600, read-only to Traefik) whenever it differs from what Traefik serves;
Traefik picks up the new files by itself. Renewing is: replace your two
files, then `./mediastack.sh up` (the panel's Up button does the same).

`doctor` warns 30 days before the certificate expires and fails once it
cannot be served (7 days or less, or anything else above); it also says when
Traefik is still serving an older copy than your files.

### Checking a pair before you use it

```
openssl x509 -in fullchain.pem -noout -subject -enddate -ext subjectAltName
openssl x509 -in fullchain.pem -noout -checkhost media.example.com
openssl x509 -in fullchain.pem -noout -checkhost anything.media.example.com
diff <(openssl x509 -in fullchain.pem -noout -pubkey) <(openssl pkey -in privkey.pem -pubout) && echo "the key fits"
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted fullchain.pem <(openssl x509 -in fullchain.pem)
```

## Other DNS providers

Let's Encrypt through another DNS provider than Cloudflare is on the
roadmap (Portability), after the MVP. Until then, a certificate you obtain
elsewhere — with any provider's DNS — is the "your own" choice.
