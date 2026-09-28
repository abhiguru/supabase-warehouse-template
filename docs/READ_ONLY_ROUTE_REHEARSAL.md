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
test object whose access has been verified. Never use a wildcard or allow a
write endpoint. Query strings are forwarded for exact allowed paths, so keep
signed links and tokens out of logs and screenshots. The proxy forwards only
the request headers needed for authenticated reads and rejects duplicate or
control-character-bearing forwarded headers. Responses over 8 MiB fail. The
proxy admits at most 32 concurrent connections and rejects excess connections
with 503; accepted sockets have a 10-second inactivity timeout.

When an internal Docker network leaves the gateway without a working host
loopback publication, add an exact `"upstream_host"` private IPv4 literal to
the private config and set `upstream_port` to Kong's container port. The proxy
still listens only on host loopback. First inspect Docker to prove that the
address belongs to the isolated Kong container on the expected internal
network, that **no** gateway port is published on the host, and that the host
can reach the container address. Recreate and recheck this configuration after
any container restart or replacement because container IPs can change. The
config loader rejects public, loopback, link-local, DNS and IPv6 values for an
explicit `upstream_host`. Do not expose Kong directly to compensate for an
unreachable upstream.

Run `python3 -B tests/read-only-route-proxy.test.py` before considering this
candidate. Then, on an **isolated restored instance**, inventory local ports
and launch the proxy against its loopback gateway or verified private Docker
address without starting its tunnel.
With the configured Host header, prove the allowed identity GET and any
approved authenticated object GET work through the proxy. Prove POST, PUT,
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
