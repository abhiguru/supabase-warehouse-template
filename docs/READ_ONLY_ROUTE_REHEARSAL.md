# Candidate read-only route barrier

`scripts/read-only-route-proxy.py` is a review-only tool for a temporary
**read-only** public-route rehearsal. It is not part of operator installation
and does not activate a tunnel or change DNS. It binds only to `127.0.0.1`,
forwards GET/HEAD for exact configured paths to a fixed configured upstream
(loopback by default, or an explicitly validated private Docker address),
and rejects other methods, paths, hosts, upgrades and request bodies. It never
logs request paths, headers or content. Its purpose is to prevent accidental
public mutations while testing identity and approved document reads; it does
not prove write-capable public recovery.

Use a private JSON configuration outside Git, owned by the installation user
and mode 0600. This **example only** uses a reserved hostname and sample
ports; inventory the target first and choose its actual local values:

```json
{
  "canonical_host": "api.example.test",
  "listen_port": 18001,
  "upstream_port": 18000,
  "allowed_paths": ["/functions/v1/get-public-config"]
}
```

Add an exact `/storage/v1/object/authenticated/...` path only for an approved
test object whose access has been verified. For a private document without a
direct client-read policy, use an exact `/storage/v1/object/sign/...` path for
that one object and a short-lived signed link created privately on the isolated
restore. The signed path accepts only one nonempty `token` query parameter and
rejects Authorization and apikey headers; the proxy sets `Cache-Control:
private, no-store` and `Cloudflare-CDN-Cache-Control: no-store` on its response.
The restored signing secret is also live on the original pilot. A signed URL
for an archived object may therefore work on the pilot hostname too. For a
public rehearsal, use a unique test-only object path created solely on the
isolated restore. If the goal is to compare document bytes, copy the verified
restored PDF to that path privately, then state that the public result proves
delivery of identical bytes, not the archived object's own URL. Confirm the
test path is absent from the archive, remove it after the test, and compare
business rows and original object bytes before and after. Never send a
service-role credential through the public route.
Inspect the separate hostname's Cloudflare Cache Rules before exposing it:
an Edge TTL that ignores origin cache headers can still cache private bytes.
Never use a wildcard or allow a write endpoint. Keep signed links and tokens
out of logs and screenshots. The proxy forwards only
the request headers needed for authenticated reads and rejects duplicate or
control-character-bearing forwarded headers. Responses over 8 MiB fail. The
proxy admits at most 32 concurrent connections and rejects excess connections
with 503; accepted sockets have a 10-second inactivity timeout.

When an internal Docker network leaves the gateway without a working host
loopback publication, add an exact `"upstream_host"` private IPv4 literal to
the private config and set `upstream_port` to Kong's container port. The proxy
still listens only on host loopback. First inspect Docker to prove that the
address belongs to the isolated Kong container on the expected internal
network, that **no non-loopback** gateway port is published on the host, and
that the host can reach the container address. Docker may retain a configured
`127.0.0.1` port binding even when the internal network gives it no effective
host listener; inspect effective ports and listeners as well as the binding.
Recreate and recheck this configuration after
any container restart or replacement because container IPs can change. The
config loader rejects public, loopback, link-local, DNS and IPv6 values for an
explicit `upstream_host`. Do not expose Kong directly to compensate for an
unreachable upstream.

Run `python3 -B tests/read-only-route-proxy.test.py` before considering this
candidate. Then, on an **isolated restored instance**, inventory local ports
and launch the proxy against its loopback gateway or verified private Docker
address without starting its tunnel.
With the configured Host header, prove the allowed identity GET and any
approved authenticated or signed object GET work through the proxy. Prove POST, PUT,
PATCH, DELETE, OPTIONS, unlisted paths, wrong Host, upgrades and request
bodies are denied without reaching the gateway. Confirm the gateway has no
other public ingress, and compare business rows and objects before and after
to detect background writes outside this HTTP barrier. Stop if any check
fails. Keep raw request tokens and test output private.

Only after review, isolated target checks and separate cutover authorization
could a temporary tunnel point at the proxy. Stop the serving connector
before starting another connector for the same tunnel, and restore the
original route only after proving the test connector inactive. This barrier
cannot accept a full public-service RTO or support a permanent move: both
require a current backup destination, safe single-writer handoff and an
approved plan for writes after cutover.

## Local rehearsal checkpoint — 2026-09-29

The proxy at `11189f76712124e09786dc81878ff8e21a491b64` passed all eight
current unit tests (the original test request named five). A new isolated
restore using recovery candidate `162e16cb1231fe87a7f0f89da8b77e05f1c54167`
passed disposable verification and installer actions prepare, restore, build,
cache, verify and stop. This reused a previously verified private archive;
it was a local proxy confirmation, not a new RPO/RTO sample.

The restored ten-service network was internal. Only Kong had a loopback host
binding; probes found no non-loopback gateway listener, and no `cloudflared`
connector ran. The proxy itself listened only on loopback. Through it, the
identity endpoint and one exact signed path for an isolated-only PDF copy
returned allowed reads. The PDF bytes matched the restored document's SHA-256
`2219425cb01f43b44b541b24508b6bb45ea0d5f433c50b3004876e5d0832c789`.
Missing and invalid tokens, an Authorization header, wrong Host, upgrade,
unlisted business and archived-object paths, and POST, PUT, PATCH, DELETE and
OPTIONS were denied. Signed responses carried private and CDN no-store headers.

The temporary object was removed. The original object and storage catalog were
unchanged; business data-only dumps before and after were byte-identical
(SHA-256 `b87631b39ce8dc417f87aa38e6feb5fa012ce785233c534cc0c6c2c57e85f9b9`).
The proxy and drill containers were stopped, with no remaining listener on the
test ports. DNS and tunnel routing were untouched. Raw logs, signed URLs and
the restored state remain private outside Git. This closes the requested
**local** proxy rehearsal; it does not prove an independent remote client's
access, public write recovery, or a production cutover.
