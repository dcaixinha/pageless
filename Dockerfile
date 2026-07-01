# =============================================================================
# Build stage
# =============================================================================
FROM hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-20260316-slim AS build

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod
ARG VERSION=dev
ENV PAGELESS_VERSION=${VERSION}

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Cache dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy config before the rest so we can compile
COPY config config

# Copy application code
COPY lib lib
COPY priv priv
COPY assets assets
COPY rel rel

# Compile the project first -- colocated JS hooks are generated during compilation
# and must exist before esbuild bundles app.js
RUN mix compile

# Build assets and digest
RUN mix assets.deploy

# Build the release
RUN mix release

# =============================================================================
# Runtime stage
# =============================================================================
FROM debian:bookworm-20260316-slim AS runtime

ARG VERSION=dev
ENV PAGELESS_VERSION=${VERSION}

# ffmpeg provides ffprobe + ffmpeg used by the library scanner.
RUN apt-get update && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    ca-certificates \
    curl \
    gosu \
    ffmpeg \
    inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Create a non-root user
RUN groupadd --system pageless && useradd --system --gid pageless pageless

# Media artifacts (extracted covers, etc.) live outside the release.
ENV PAGELESS_MEDIA_PATH=/data/media
RUN mkdir -p /data/media && chown -R pageless:pageless /data

# Copy the release from the build stage
COPY --from=build --chown=pageless:pageless /app/_build/prod/rel/pageless ./

# Include source and bundled-font license notices in the distributed image.
COPY --chown=pageless:pageless LICENSE THIRD_PARTY_NOTICES ./licenses/

# Copy the entrypoint script. It starts as root so it can optionally remap the
# pageless UID/GID to match host-mounted volumes, then drops privileges via gosu.
COPY rel/entrypoint.sh ./entrypoint.sh

ENV PHX_SERVER=true

ENTRYPOINT ["./entrypoint.sh"]
CMD ["start"]
