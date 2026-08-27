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
  local bucket
  local mc_config_dir="${MC_CONFIG_DIR:-$HOME/.mc}"
  local managed_aliases_file="${mc_config_dir}/.dba-toolbox-managed-aliases"
  local bucket_file="${S3_BUCKETS_FILE:-${HOME}/.s3-buckets}"
  local next_managed_aliases
  local next_bucket_file
  local old_alias

  mkdir -p "$mc_config_dir" "$(dirname "$bucket_file")"

  # Remove aliases from the previous rendered Secret before applying the
  # current one. User-created aliases are not listed in this file and survive.
  if [ -f "$managed_aliases_file" ]; then
    while IFS= read -r old_alias; do
      [ -n "$old_alias" ] || continue
      mc alias rm "$old_alias" >/dev/null 2>&1 || true
    done <"$managed_aliases_file"
  fi

  count="$(discover_count MINIO)"
  if [ "$count" -eq 0 ]; then
    log "No MinIO aliases configured"
    : >"$managed_aliases_file"
    : >"$bucket_file"
    chmod 0600 "$managed_aliases_file" "$bucket_file"
    return
  fi

  next_managed_aliases="$(mktemp "${mc_config_dir}/.managed-aliases.XXXXXX")"
  next_bucket_file="$(mktemp "${bucket_file}.XXXXXX")"
  trap 'rm -f "$next_managed_aliases" "$next_bucket_file"' RETURN

  for ((index = 0; index < count; index++)); do
    prefix="MINIO_${index}"
    alias_name="$(getenv "${prefix}_ALIAS")"
    endpoint="$(getenv "${prefix}_ENDPOINT")"
    access_key="$(getenv "${prefix}_ACCESS_KEY")"
    secret_key="$(getenv "${prefix}_SECRET_KEY")"
    api="$(getenv "${prefix}_API")"
    path_mode="$(getenv "${prefix}_PATH")"
    bucket="$(getenv "${prefix}_BUCKET")"

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
    printf '%s\n' "$alias_name" >>"$next_managed_aliases"
    if [ -n "$bucket" ]; then
      printf '%s=%s\n' "$alias_name" "$bucket" >>"$next_bucket_file"
    fi
  done

  chmod 0600 "$next_managed_aliases" "$next_bucket_file"
  mv -f "$next_managed_aliases" "$managed_aliases_file"
  mv -f "$next_bucket_file" "$bucket_file"
  trap - RETURN
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
  local connection_string
  local service_file="${PGSERVICEFILE:-${HOME}/.pg_service.conf}"
  local pass_file="${PGPASSFILE:-${HOME}/.pgpass}"
  local service_dir
  local pass_dir
  local next_service_file
  local next_pass_file

  count="$(discover_count POSTGRES)"
  service_dir="$(dirname "$service_file")"
  pass_dir="$(dirname "$pass_file")"
  mkdir -p "$service_dir" "$pass_dir"
  if [ "$count" -eq 0 ]; then
    log "No PostgreSQL services configured"
    : >"$service_file"
    : >"$pass_file"
    chmod 0600 "$service_file" "$pass_file"
    return
  fi

  next_service_file="$(mktemp "${service_file}.XXXXXX")"
  next_pass_file="$(mktemp "${pass_file}.XXXXXX")"
  trap 'rm -f "$next_service_file" "$next_pass_file"' RETURN

  for ((index = 0; index < count; index++)); do
    prefix="POSTGRES_${index}"
    service_name="$(getenv "${prefix}_SERVICE")"
    host="$(getenv "${prefix}_HOST")"
    port="$(getenv "${prefix}_PORT")"
    database="$(getenv "${prefix}_DATABASE")"
    user="$(getenv "${prefix}_USER")"
    password="$(getenv "${prefix}_PASSWORD")"
    sslmode="$(getenv "${prefix}_SSLMODE")"
    connection_string="$(getenv "${prefix}_CONNECTION_STRING")"

    require_value "${prefix}_SERVICE" "$service_name"
    port="${port:-5432}"

    if [ -n "$connection_string" ]; then
      log "Configuring PostgreSQL service ${service_name} from a connection string"
      {
        printf '[%s]\n' "$service_name"
        append_pg_service_option "$next_service_file" dbname "$connection_string"
        printf '\n'
      } >>"$next_service_file"
    else
      require_value "${prefix}_HOST" "$host"
      require_value "${prefix}_DATABASE" "$database"
      require_value "${prefix}_USER" "$user"
      require_value "${prefix}_PASSWORD" "$password"

      log "Configuring PostgreSQL service ${service_name} for ${user}@${host}:${port}/${database}"
      {
        printf '[%s]\n' "$service_name"
        append_pg_service_option "$next_service_file" host "$host"
        append_pg_service_option "$next_service_file" port "$port"
        append_pg_service_option "$next_service_file" dbname "$database"
        append_pg_service_option "$next_service_file" user "$user"
        append_pg_service_option "$next_service_file" sslmode "$sslmode"
        printf '\n'
      } >>"$next_service_file"

      printf '%s:%s:%s:%s:%s\n' "$host" "$port" "$database" "$user" "$password" >>"$next_pass_file"
    fi
  done

  chmod 0600 "$next_service_file" "$next_pass_file"
  mv -f "$next_service_file" "$service_file"
  mv -f "$next_pass_file" "$pass_file"
  trap - RETURN
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
