# Self-hosting Pageless

This guide shows a production-oriented Docker Compose setup for running Pageless
behind a reverse proxy. It assumes the published image from the release workflow:

```text
dcaixinha/pageless:latest
```

Release-specific tags are timestamp based, for example:

```text
dcaixinha/pageless:20260708230000-abcdef123
```

## Compose Example

```yaml
services:
  db:
    image: postgres:18-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: pageless
      POSTGRES_PASSWORD: change-me
      POSTGRES_DB: pageless
    volumes:
      # Postgres 18+ stores data in a versioned subdirectory under this path.
      - ./postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pageless"]
      interval: 10s
      timeout: 5s
      retries: 5

  pageless:
    image: dcaixinha/pageless:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    volumes:
      # Persist extracted covers and other media artifacts.
      - ./media:/data/media

      # Mount your audiobook library read-only. Use this path when adding a
      # library folder in the Pageless admin UI.
      - ./audiobooks:/audiobooks:ro
    environment:
      TZ: Europe/Lisbon
      PHX_HOST: pageless.example.com
      PORT: 5050
      SECRET_KEY_BASE: replace-with-output-of-mix-phx-gen-secret
      DATABASE_URL: ecto://pageless:change-me@db/pageless
      PAGELESS_MEDIA_PATH: /data/media

      # Optional: run the app as a UID/GID that matches your host-mounted
      # volumes.
      # This is useful when using bind mounts managed by another app/user.
      # PAGELESS_UID: 82
      # PAGELESS_GID: 82

      # If you use nginx-proxy/acme-companion style automation
      VIRTUAL_HOST: pageless.example.com
      VIRTUAL_PORT: 5050
      LETSENCRYPT_HOST: pageless.example.com
      LETSENCRYPT_EMAIL: you@example.com
    networks:
      - default
      - main-network

networks:
  main-network:
    external: true
```

## HTTPS Reverse Proxy

Production deployments require an HTTPS reverse proxy. Pageless listens for
plain HTTP on its internal port and relies on the proxy to terminate TLS. The
proxy must preserve the original `Host` header and send
`X-Forwarded-Proto: https`.

Do not expose port `5050` directly as the public production endpoint. Pageless
forces HTTPS in production, so direct HTTP requests would be redirected to an
HTTPS port where Pageless itself is not serving TLS. If you use a different
proxy, replace `main-network` and the nginx-proxy environment variables with
that proxy's equivalent network and routing configuration.

## Required Environment

`SECRET_KEY_BASE` is required in production. Generate one locally with:

```sh
mix phx.gen.secret
```

`DATABASE_URL` must point to a PostgreSQL database. The container entrypoint runs
database creation and migrations before starting the server:

```sh
bin/pageless eval "Pageless.Release.create_and_migrate()"
```

The database user therefore needs permission to create the configured database on
first boot. If your managed database does not permit database creation, create the
database manually first; migrations will still run.

## First Boot

1. Start the stack:

   ```sh
   docker compose up -d
   ```

2. Open Pageless in a browser.
3. If no users exist, Pageless redirects to `/setup`.
4. Create the first admin account.
5. Go to Settings -> Libraries and add `/audiobooks` as a library folder.
6. The library scan starts automatically after creation.

## Volumes

Recommended persistent volumes/directories:

- `./postgres` for PostgreSQL data.
- `./media` mounted at `/data/media` for extracted cover art and derived media.
- Your audiobook library mounted read-only at `/audiobooks`.

Pageless does not need write access to your audiobook library for normal scanning.

If your host-mounted media directory needs a specific owner, set `PAGELESS_UID`
and `PAGELESS_GID`. On startup, the container updates the internal `pageless`
user/group to those IDs, ensures `PAGELESS_MEDIA_PATH` exists, and makes that
media path writable by the `pageless` user before running migrations and
starting the app. The audiobook library can remain read-only.

## Updating

If you use `latest`:

```sh
docker compose pull pageless
docker compose up -d pageless
```

If you prefer pinned releases, replace `latest` with a timestamp tag from the
GitHub release page or Docker Hub.

## Notes

- The app listens on port `5050` by default.
- `ffmpeg`/`ffprobe` are included in the production image for library scanning.
- `inotify-tools` is included for automatic library file-change detection on Linux.
- [The mobile app](https://github.com/dcaixinha/pageless-mobile) should point at your public HTTPS URL, e.g.
  `https://pageless.example.com`.
