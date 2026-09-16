# shellcheck shell=bash
# Function-only library: callers own shell options, traps, and error handling.
# Config queries read RITE_STATUS_CONFIG_PATH when it is an absolute path, otherwise
# the current repository root (or cwd outside Git). No cache: helpers and tests can
# change configuration between calls in the same shell.

projects_status_path_is_absolute() {
  case "${1-}" in
    /*|[A-Za-z]:[\\/]*) return 0 ;;
    *) return 1 ;;
  esac
}

_projects_status_read() {
  local root config
  if [[ -n "${RITE_STATUS_CONFIG_PATH:-}" ]]; then
    config="$RITE_STATUS_CONFIG_PATH"
    projects_status_path_is_absolute "$config" || {
      printf 'ERROR: RITE_STATUS_CONFIG_PATH must be an absolute path\n' >&2
      return 1
    }
  else
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
    config="$root/rite-config.yml"
  fi
  if [[ ! -r "$config" ]]; then
    printf 'ERROR: projects status config is missing or unreadable: %s\n' "$config" >&2
    return 1
  fi
  # Environment bindings preserve literal backslashes in lookup names; awk -v
  # would interpret them as escapes before comparing them with parsed values.
  RITE_STATUS_QUERY="$1" RITE_STATUS_VALUE="${2-}" awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function quote_start(s,i) { return substr(s,1,i-1) ~ /(^|[:{,])[ \t]*$/ }
    function fail(message) {
      print "ERROR: github.projects.fields.status: " message > "/dev/stderr"
      failed = 1
      exit 1
    }
    function uncomment(s,    i,c,q,escaped,out) {
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (escaped) { escaped=0; out=out c; continue }
        if (q == "\"" && c == "\\") escaped=1
        else if (q && c == q) q=""
        else if (!q && (c == "\"" || c == sprintf("%c",39)) && quote_start(s,i)) q=c
        else if (!q && c == "#" && (i==1 || substr(s,i-1,1) ~ /[ \t]/)) break
        out=out c
      }
      return trim(out)
    }
    function scalar(s,    i,c,out) {
      s=trim(s)
      if (substr(s,1,1) == "\"") {
        if (length(s)<2 || substr(s,length(s),1)!="\"") { syntax=1; return "" }
        for (i=2; i<length(s); i++) {
          c=substr(s,i,1)
          if (c == "\\") {
            c=substr(s,++i,1)
            if (i>=length(s) || (c!="\\" && c!="\"" && c!="/")) syntax=1
          } else if (c=="\"") syntax=1
          out=out c
        }
      } else {
        if (s ~ /^[!&*|>@`\047"{}\[\],?]/ || s ~ /[{}\[\],]/ || s ~ /:[ \t]/) syntax=1
        if (s=="null" || s=="~") syntax=1
        out=s
      }
      if (out ~ /[[:cntrl:]]/) syntax=1
      return out
    }
    function member(s,    key,value) {
      s=trim(s)
      if (s ~ /^[\047"]role[\047"][ \t]*:/) explicit=1
      if (s !~ /^[a-z_]+[ \t]*:/) { syntax=1; return }
      key=s; sub(/[ \t]*:.*/, "", key)
      sub(/^[a-z_]+[ \t]*:[ \t]*/, "", s)
      if (member_seen[key]++) syntax=1
      if (key=="role") { explicit=1; role_seen=1; role=scalar(s) }
      else if (key=="name") { name_seen=1; name=scalar(s) }
      else if (key=="default") { if (s!="true" && s!="false") syntax=1 }
      else syntax=1
    }
    function option(s,    i,c,q,escaped,piece,bare) {
      role=""; name=""; role_seen=0; name_seen=0
      for (i in member_seen) delete member_seen[i]
      # Only unquoted keys signal explicit mode; a display name may contain
      # literal text such as "role: todo" without declaring a role.
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (escaped) { escaped=0; continue }
        if (q=="\"" && c=="\\") escaped=1
        else if (q && c==q) q=""
        else if (!q && (c=="\"" || c==sprintf("%c",39)) && quote_start(s,i)) q=c
        else if (!q) bare=bare c
      }
      if (bare ~ /(^|[ {,\t-])role[ \t]*:/) explicit=1
      if (s !~ /^-[ \t]*\{.*\}$/) {
        if (s ~ /^-[ \t]+name[ \t]*:/) {
          sub(/^-[ \t]+name[ \t]*:[ \t]*/, "", s)
          name=scalar(s)
          if (name !~ /[^ \t]/) syntax=1
          block_option=1; unroled++
        } else if (block_option && s ~ /^default[ \t]*:[ \t]*(true|false)$/) {
          block_option=0
        } else syntax=1
        return
      }
      block_option=0
      sub(/^-[ \t]*\{/, "", s); sub(/\}$/, "", s)
      q=""; escaped=0
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1)
        if (escaped) { escaped=0; piece=piece c; continue }
        if (q=="\"" && c=="\\") escaped=1
        else if (q && c==q) q=""
        else if (!q && (c=="\"" || c==sprintf("%c",39)) && quote_start(s,i)) q=c
        else if (!q && c==",") { member(piece); piece=""; continue }
        piece=piece c
      }
      if (q || escaped) syntax=1
      member(piece)
      if (!name_seen || name !~ /[^ \t]/) syntax=1
      if (!role_seen) unroled++
      if (role_seen) {
        if (role !~ /^(todo|in_progress|in_review|done|cancelled)$/) invalid="unknown or empty role"
        if (!name_seen || name !~ /[^ \t]/) invalid="role names must be nonempty"
        if (role in names) invalid="duplicate role"
        if (name in roles) invalid="duplicate name"
        names[role]=name; roles[name]=role
      }
    }
    {
      raw=$0
      line=uncomment(raw)
      if (line=="" || line=="---") next
      match(raw,/^[ \t]*/); indent=RLENGTH
      if (in_options && indent>options_indent) { option(line); next }
      in_options=0
      while (depth && indent<=indents[depth]) depth--
      path=""
      for (i=1;i<=depth;i++) path=path keys[i] "."
      key=line; sub(/:.*/, "", key); key=trim(key)
      # Recognize quoted target keys so unsupported syntax cannot look absent.
      if (key ~ /^"[^"]*"$/ || key ~ /^\047[^\047]*\047$/) key=substr(key,2,length(key)-2)
      path=path key
      relevant=(path=="github" || path=="github.projects" || path=="github.projects.fields" || path=="github.projects.fields.status")
      if (relevant || path ~ /^github\.projects\.fields\.status\./) {
        if (raw ~ /^ *\t/ || line !~ /^[a-z_]+[ \t]*:/) fail("unsupported syntax")
        if (seen[path]++) fail("duplicate configuration key")
        value=line; sub(/^[a-z_]+[ \t]*:[ \t]*/, "", value)
        if (relevant && value!="") fail("nested configuration must use block mappings")
        if (path=="github.projects.fields.status.name") {
          option_syntax=syntax; syntax=0
          field=scalar(value)
          if (syntax || field !~ /[^ \t]/) fail("field name must be a nonempty scalar")
          syntax=option_syntax
        }
        if (path=="github.projects.fields.status.options") {
          if (value!="" && value!="[]") fail("options must use a block list")
          in_options=1; options_indent=indent
        }
      }
      if (line ~ /^[a-zA-Z_][a-zA-Z_0-9-]*[ \t]*:/) {
        depth++; indents[depth]=indent; keys[depth]=key
      }
    }
    END {
      if (failed) exit 1
      if (syntax) fail("unsupported option syntax; use - { role: todo, name: \"Todo\" }")
      if (explicit) {
        if (unroled) fail("role and no-role options cannot be mixed")
        if (invalid!="") fail(invalid)
        if (!("todo" in names) || !("in_progress" in names) || !("in_review" in names) || !("done" in names))
          fail("todo, in_progress, in_review, and done roles are required")
      } else {
        names["todo"]="Todo"; names["in_progress"]="In Progress"
        names["in_review"]="In Review"; names["done"]="Done"; names["cancelled"]="Cancelled"
        for (role in names) roles[names[role]]=role
      }
      query=ENVIRON["RITE_STATUS_QUERY"]; value=ENVIRON["RITE_STATUS_VALUE"]
      if (query=="mode") print explicit ? "explicit" : "legacy"
      else if (query=="name") { if (value in names) print names[value] }
      else if (query=="role") { if (value in roles) print roles[value] }
      else if (query=="fields") {
        if (field!="") print field
        else print "ステータス\nStatus"
      }
    }
  ' "$config"
}

# Print legacy/explicit, or return nonzero with an invalid-config diagnostic.
projects_status_mode() { _projects_status_read mode; }

# Print the mapped name/role, or nothing for an unmapped value. Config errors
# return nonzero even when the requested role or name would otherwise be absent.
projects_status_name_for_role() { _projects_status_read name "${1-}"; }
projects_status_role_for_name() { _projects_status_read role "${1-}"; }

# Print configured field name only, or Japanese then English default candidates.
projects_status_field_candidates() { _projects_status_read fields; }

# cancelled is terminal, but has no progress rank.
projects_status_rank() {
  case "${1-}" in
    todo) printf '1\n' ;; in_progress) printf '2\n' ;;
    in_review) printf '3\n' ;; done) printf '4\n' ;; *) printf '0\n' ;;
  esac
}
projects_status_is_terminal() { [[ "${1-}" == done || "${1-}" == cancelled ]]; }
