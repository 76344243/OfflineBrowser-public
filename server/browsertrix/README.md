# Optional Browsertrix service

OfflineBrowser has a local archive engine and works without this directory. The
service described here is an optional deployment for pages whose client-side
JavaScript, embedded frames, or lazy-loaded media are difficult to capture from
an iOS WebView alone.

The service is intentionally small and single-worker:

1. the app submits a URL, a stable job identifier, and a crawl depth;
2. the adapter starts the pinned Browsertrix Crawler image;
3. the adapter reports crawl progress and verifies the resulting WACZ archive;
4. the app downloads the verified archive and replays it locally, without a
   live network fallback.

## Deploying

The files assume a Linux host with Docker and Python 3. Create a private
service directory, copy `service.py` and `behaviors/` there, and provide a
random bearer token through an environment file. `service.env.example` shows
the required variables. Do not commit the real environment file or generated
archives.

Run the adapter behind an existing HTTPS reverse proxy. The included
`nginx-location.conf` is an example location block; adapt the public path and
TLS policy to your own deployment. Bind the Python service to loopback only,
keep the token private, and restrict the host's outbound and inbound access as
appropriate for a crawler.

The adapter exposes only the small API used by the app:

```text
POST   /jobs
GET    /jobs/<id>
POST   /jobs/<id>/pause
POST   /jobs/<id>/resume
GET    /jobs/<id>/archive
DELETE /jobs/<id>
```

The service validates HTTP(S) URLs, rejects credentials embedded in URLs, and
rejects non-public target addresses. Review these policies before deploying in
an environment with different network requirements. Add rate limiting,
monitoring, backups, and a retention policy suitable for your use case.

## Licensing

The adapter and deployment examples are part of this repository. The runtime
Browsertrix Crawler image is a separate third-party component; see the root
`THIRD_PARTY_NOTICES.md` for its license and upstream project.
