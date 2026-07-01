#!/bin/sh
set -eu

if [ "$(id -u)" = "0" ]; then
  current_gid="$(id -g pageless)"
  if [ -n "${PAGELESS_GID:-}" ] && [ "${PAGELESS_GID}" != "${current_gid}" ]; then
    echo "==> Setting pageless GID to ${PAGELESS_GID}..."
    groupmod -o -g "${PAGELESS_GID}" pageless
  fi

  current_uid="$(id -u pageless)"
  if [ -n "${PAGELESS_UID:-}" ] && [ "${PAGELESS_UID}" != "${current_uid}" ]; then
    echo "==> Setting pageless UID to ${PAGELESS_UID}..."
    usermod -o -u "${PAGELESS_UID}" pageless
  fi

  media_path="${PAGELESS_MEDIA_PATH:-/data/media}"
  mkdir -p "${media_path}"
  chown -R pageless:pageless "${media_path}"

  run_as_pageless="gosu pageless"
else
  run_as_pageless=""
fi

echo "==> Running database migrations..."
${run_as_pageless} bin/pageless eval "Pageless.Release.create_and_migrate()"
echo "==> Migrations complete."

echo "==> Starting Pageless..."
exec ${run_as_pageless} bin/pageless "$@"
