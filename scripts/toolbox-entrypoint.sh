#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

getenv() {
  local name="$1"
  printf '%s' "${!name-}"
}

require_value() {
  local name="$1"
  local value="$2"

  if [ -z "$value" ]; then
    log "ERROR: Missing required environment variable: ${name}"
    exit 1
  fi
}

discover_count() {
  local prefix="$1"
  local explicit_count
  local max_index=-1
  local name

  explicit_count="$(getenv "${prefix}_COUNT")"
  if [ -n "$explicit_count" ]; then
    printf '%s' "$explicit_count"
    return
  fi

  for name in $(compgen -e); do
    if [[ "$name" =~ ^${prefix}_([0-9]+)_ ]]; then
      if [ "${BASH_REMATCH[1]}" -gt "$max_index" ]; then
        max_index="${BASH_REMATCH[1]}"
      fi
    fi
  done

  printf '%s' "$((max_index + 1))"
}

setup_minio() {
  local count
  local index
  local prefix
  local alias_name
  local endpoint
  local access_key
  local secret_key
  local api
  local path_mode

  count="$(discover_count MINIO)"
  if [ "$count" -eq 0 ]; then
    log "No MinIO aliases configured"
    return
  fi

  mkdir -p "${HOME}/.mc"

  for ((index = 0; index < count; index++)); do
    prefix="MINIO_${index}"
    alias_name="$(getenv "${prefix}_ALIAS")"
    endpoint="$(getenv "${prefix}_ENDPOINT")"
    access_key="$(getenv "${prefix}_ACCESS_KEY")"
    secret_key="$(getenv "${prefix}_SECRET_KEY")"
    api="$(getenv "${prefix}_API")"
    path_mode="$(getenv "${prefix}_PATH")"

    require_value "${prefix}_ALIAS" "$alias_name"
    require_value "${prefix}_ENDPOINT" "$endpoint"
    require_value "${prefix}_ACCESS_KEY" "$access_key"
    require_value "${prefix}_SECRET_KEY" "$secret_key"

    api="${api:-S3v4}"
    path_mode="${path_mode:-auto}"

    log "Configuring MinIO alias ${alias_name} for ${endpoint}"
    mc alias set "$alias_name" "$endpoint" "$access_key" "$secret_key" \
      --api "$api" \
      --path "$path_mode" >/dev/null
  done
}

append_pg_service_option() {
  local file="$1"
  local key="$2"
  local value="$3"

  [ -n "$value" ] || return 0
  printf '%s=%s\n' "$key" "$value" >>"$file"
}

setup_postgres() {
  local count
  local index
  local prefix
  local service_name
  local host
  local port
  local database
  local user
  local password
  local sslmode
  local service_file="${HOME}/.pg_service.conf"
  local pass_file="${HOME}/.pgpass"

  count="$(discover_count POSTGRES)"
  if [ "$count" -eq 0 ]; then
    log "No PostgreSQL services configured"
    return
  fi

  : >"$service_file"
  : >"$pass_file"
  chmod 0600 "$service_file" "$pass_file"

  for ((index = 0; index < count; index++)); do
    prefix="POSTGRES_${index}"
    service_name="$(getenv "${prefix}_SERVICE")"
    host="$(getenv "${prefix}_HOST")"
    port="$(getenv "${prefix}_PORT")"
    database="$(getenv "${prefix}_DATABASE")"
    user="$(getenv "${prefix}_USER")"
    password="$(getenv "${prefix}_PASSWORD")"
    sslmode="$(getenv "${prefix}_SSLMODE")"

    require_value "${prefix}_SERVICE" "$service_name"
    require_value "${prefix}_HOST" "$host"
    require_value "${prefix}_DATABASE" "$database"
    require_value "${prefix}_USER" "$user"
    require_value "${prefix}_PASSWORD" "$password"

    port="${port:-5432}"

    log "Configuring PostgreSQL service ${service_name} for ${user}@${host}:${port}/${database}"
    {
      printf '[%s]\n' "$service_name"
      append_pg_service_option "$service_file" host "$host"
      append_pg_service_option "$service_file" port "$port"
      append_pg_service_option "$service_file" dbname "$database"
      append_pg_service_option "$service_file" user "$user"
      append_pg_service_option "$service_file" sslmode "$sslmode"
      printf '\n'
    } >>"$service_file"

    printf '%s:%s:%s:%s:%s\n' "$host" "$port" "$database" "$user" "$password" >>"$pass_file"
  done
}

main() {
  mkdir -p "$HOME"

  setup_minio
  setup_postgres

  log "Toolbox ready"
  trap 'exit 0' TERM INT
  sleep infinity &
  wait
}

main "$@"
