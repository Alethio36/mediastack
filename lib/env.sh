#!/usr/bin/env bash
# lib/env.sh — .env against its schema (lib/env.schema.tsv). Values are
# checked on every command (load_env): a malformed one stops the command with
# the key, what is wrong and what is expected. Keys nothing reads are only
# reported, by doctor. No guessing at misspelt names: a key is a setting or
# it is not. A key you mean to keep marks itself with a comment line directly
# above it:
#     # mediastack: ignore
#     MY_OWN_VAR=value
# Sourced by the entrypoint; relies on lib/common.sh (env_get, die, warn) and,
# for the unknown-key report, the render/svc helpers at call time.

ENV_SCHEMA_FILE="$SCRIPT_DIR/lib/env.schema.tsv"
ENV_IGNORE_MARK="# mediastack: ignore"
ENV_ROOTS_RE='(CONFIG|DATA|CACHE|TRANSCODE|BACKUP)_ROOT'

env_schema_rows() { grep -vE '^(#|[[:space:]]*$)' "$ENV_SCHEMA_FILE"; }   # key type empty writer meaning

# one awk pass: the schema's rows, then KEY=VALUE lines; prints
# key <TAB> type <TAB> empty <TAB> value for every key the schema knows —
# its own row, else the family with the longest matching part. A family key
# counts only for a service that exists (stems: " RADARR RADARR_4K MYAPP "),
# so MYAPP_DB_NAME is never taken for a container name.
ENV_LOOKUP_AWK='
    function lookup(k,   i, f, p, s, ok, best, bl) {
        if (k in exact) return exact[k]
        best = ""; bl = 0
        for (i = 1; i <= n; i++) {
            split(fam[i], f, "\t"); p = f[1]
            if (p ~ /^<svc>_/)       { s = substr(p, 6); ok = (length(k) > length(s) && substr(k, length(k) - length(s) + 1) == s && index(stems, " " substr(k, 1, length(k) - length(s)) " ")) }
            else if (p ~ /^<root>_/) { s = substr(p, 7); ok = (length(k) > length(s) && substr(k, length(k) - length(s) + 1) == s && substr(k, 1, length(k) - length(s)) ~ ("^" roots "$")) }
            else                     { s = substr(p, 1, length(p) - 5); ok = (index(k, s) == 1 && index(stems, " " substr(k, length(s) + 1) " ")) }
            if (ok && length(s) > bl) { bl = length(s); best = f[2] "\t" f[3] }
        }
        return best
    }
    FNR == NR {
        if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) next
        if ($1 ~ /^<svc>_/ || $1 ~ /^<root>_/ || $1 ~ /<arr>$/) fam[++n] = $0
        else exact[$1] = $2 "\t" $3
        next
    }
    match($0, /^[A-Z][A-Z0-9_]*=/) {
        k = substr($0, 1, RLENGTH - 1); r = lookup(k)
        if (r != "") print k "\t" r "\t" substr($0, RLENGTH + 1)
    }'

env_stems() { # every service's variable stem, from the compose files themselves (no docker needed)
    local f
    for f in compose.d/*.yml "$DROPIN_DIR"/*.yml "$OVERRIDE_FILE"; do
        [[ -e "$f" ]] && yaml_services "$f"
    done | sort -u | while read -r f; do printf '%s ' "$(uvar "$f")"; done   # uvar prints no newline
}

env_schema_known() { # env_schema_known FILE -> key <TAB> type <TAB> empty <TAB> value, for every schema-known key in FILE
    awk -F'\t' -v roots="$ENV_ROOTS_RE" -v stems=" $(env_stems)" "$ENV_LOOKUP_AWK" "$ENV_SCHEMA_FILE" "$1"
}

env_schema_lookup() { # env_schema_lookup KEY -> "type<TAB>empty" of its row (its own, else its family's); rc 1 when none
    local out; out=$(env_schema_known <(echo "$1=")) || return 1
    [[ -n "$out" ]] || return 1
    out=${out#*$'\t'}; echo "${out%$'\t'*}"
}

env_type_expect() { # what a value of TYPE looks like, for a message
    case "$1" in
        text|secret) echo "any single-line text" ;;
        path)     echo "a folder path" ;;
        dirname)  echo "one folder name (no /)" ;;
        int)      echo "a whole number (0 or more)" ;;
        pint)     echo "a whole number (1 or more)" ;;
        pct)      echo "a percentage (0-100)" ;;
        bool)     echo "true or false" ;;
        uid)      echo "a numeric user/group id" ;;
        port)     echo "a port number (1-65535)" ;;
        size)     echo "a size like 10m, 512k or 1g" ;;
        tz)       echo "a time zone name, e.g. Etc/UTC or Australia/Adelaide" ;;
        calendar) echo "a systemd OnCalendar expression, e.g. *-*-* 03:30 (check: systemd-analyze calendar '...')" ;;
        profiles) echo "service names, comma-separated (lowercase, digits, -)" ;;
        host)     echo "a host name label, e.g. notify (lowercase, digits, - and .)" ;;
        domain)   echo "a domain, e.g. media.example.com" ;;
        email)    echo "an e-mail address" ;;
        url)      echo "an http:// or https:// address" ;;
        cname)    echo "a container name (letters, digits, _ . -)" ;;
        enum:*)   echo "one of: ${1#enum:}" | sed 's/|/, /g' ;;
        *)        echo "?" ;;
    esac
}

env_type_ok() { # env_type_ok TYPE VALUE — rc 0 when VALUE is a TYPE
    local t="$1" v="$2"
    case "$t" in
        text|secret) return 0 ;;
        path)     [[ "$v" =~ ^[^[:space:]] && "$v" =~ [^[:space:]]$ ]] ;;
        dirname)  [[ "$v" =~ ^[^/]+$ && "$v" != . && "$v" != .. ]] ;;
        int|uid)  [[ "$v" =~ ^[0-9]+$ ]] ;;
        pint)     [[ "$v" =~ ^[1-9][0-9]*$ ]] ;;
        pct)      [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v <= 100 )) ;;
        bool)     [[ "$v" == true || "$v" == false ]] ;;
        port)     [[ "$v" =~ ^[0-9]+$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )) ;;
        size)     [[ "$v" =~ ^[0-9]+[kKmMgG]?$ ]] ;;
        tz)       if [[ -d /usr/share/zoneinfo ]]; then [[ -f "/usr/share/zoneinfo/$v" && "$v" != */../* ]]
                  else [[ "$v" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]]; fi ;;   # no zone database here to look it up in
        calendar) systemd-analyze calendar "$v" >/dev/null 2>&1 ;;
        profiles) [[ "$v" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] ;;
        host)     [[ "$v" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ;;
        domain)   [[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] ;;
        email)    [[ "$v" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ;;
        url)      [[ "$v" =~ ^https?://[^[:space:]]+$ ]] ;;
        cname)    [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ;;
        enum:*)   [[ "|${t#enum:}|" == *"|$v|"* ]] ;;
        retired:*) return 0 ;;
        *) die "lib/env.schema.tsv: unknown type '$t'" ;;
    esac
}

env_value_problem() { # env_value_problem KEY VALUE TYPE EMPTY -> what is wrong (nothing when fine)
    local k="$1" v="$2" t="$3" e="$4" shown
    shown="'$v'"; [[ "$t" == secret ]] && shown="(hidden)"
    # the script reads a value as everything after '=', exactly; compose strips
    # quotes and a trailing comment — the two would see different values
    if [[ "$v" =~ ^[\"\'] ]]; then
        echo "$k=$shown is quoted: the script reads the quotes as part of the value. Remove them."; return
    fi
    if [[ "$v" =~ [[:space:]]# ]]; then
        echo "$k=$shown has a comment after the value: the script reads it as part of the value. Move the comment to its own line above."; return
    fi
    if [[ -z "$v" ]]; then
        [[ "$e" == ok ]] || echo "$k is empty — expected $(env_type_expect "$t")."
        return
    fi
    env_type_ok "$t" "$v" || echo "$k=$shown is not $(env_type_expect "$t")."
}

env_validate() { # every value in .env that the schema knows — all problems at once, then stop
    local problems="" k t e v p
    while IFS=$'\t' read -r k t e v; do
        p=$(env_value_problem "$k" "$v" "$t" "$e")
        [[ -z "$p" ]] || problems+="  $p"$'\n'
    done < <(env_schema_known "$ENV_FILE")   # unknown keys are doctor's to report
    [[ -z "$problems" ]] && return 0
    die ".env has values mediastack cannot use:
$problems  Fix them in $ENV_FILE (what each setting means: lib/env.schema.tsv), then retry."
}

# ---------------------------------------------------- unknown keys (doctor) --
env_custom_refs() { # every ${VAR} your custom/ files use
    [[ -d "$CUSTOM_DIR" ]] || return 0
    grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$CUSTOM_DIR" 2>/dev/null | cut -c3- | sort -u
    return 0
}

env_unknown() { # -> "key<TAB>unknown" or "key<TAB>retired<TAB>N" for every key nothing reads (and not marked)
    local refs known prev="" line k row
    refs=" $(env_custom_refs | tr '\n' ' ') "
    known=$(env_schema_known "$ENV_FILE" | cut -f1,2)
    while IFS= read -r line; do
        if [[ "$line" == "$ENV_IGNORE_MARK" ]]; then prev=ignore; continue; fi
        if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)= ]]; then
            k=${BASH_REMATCH[1]}
            if [[ "$prev" != ignore && "$k" != COMPOSE_* && "$k" != DOCKER_* && "$refs" != *" $k "* ]]; then
                row=$(awk -F'\t' -v k="$k" '$1 == k { print $2; exit }' <<<"$known")
                if [[ -z "$row" ]]; then printf '%s\tunknown\n' "$k"
                elif [[ "$row" == retired:* ]]; then printf '%s\tretired\t%s\n' "$k" "${row#retired:}"
                fi
            fi
        fi
        prev=""
    done < "$ENV_FILE"
    return 0
}

_doctor_env() {
    hr "doctor: .env"
    ok "every value is well-formed (checked before any command runs)"
    local k kind since n=0
    while IFS=$'\t' read -r k kind since; do
        n=$((n + 1))
        if [[ "$kind" == retired ]]; then
            warn "$k is no longer used (since schema $since) — safe to delete from .env"
        else
            warn "$k is not a mediastack setting and nothing in custom/ uses it — a typo, a leftover, or yours? Fix it, delete it, or mark it: a line '$ENV_IGNORE_MARK' directly above it"
        fi
    done < <(env_unknown)
    (( n )) || ok "every key in .env is a setting (or marked as yours)"
    return 0
}
