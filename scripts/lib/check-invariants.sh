#!/usr/bin/env bash
# Repository content invariants: the compiler/renderer core must stay
# target-agnostic, the game and runtime library sources must never write
# to the terminal, and LuaCATS/diagnostic source policy holds without
# exception inventories (LuaLS owns diagnostic semantics; this gate owns
# lexical source form). lint.sh is the single static gate. Default scope is
# git-tracked Lua sources and the fixed core-module list; explicit path
# arguments run the file rules over the given files (self-test hook, so a
# planted violation is demonstrable without touching tracked files).
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0
violation() {
  echo "invariants: $1" >&2
  fail=1
}

# Targeted text check, not a Lua parser: recognizes only assigned
# `= function(` and directly returned `return function(` forms.
check_assigned_or_returned_anonymous_function_file() {
  local path="$1"
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*-- ]] && continue
    if [[ "$line" =~ =\ function\( ]] || [[ "$line" =~ return\ function\( ]]; then
      return 0
    fi
  done < "$path"
  return 1
}

# Check A — target-specific branches in the core. A missing module is a
# violation: the gate must not silently skip a core file.
check_forbidden_phrases() {
  local path="$1"
  local phrases=(MAP_NEW_BARK ELMS_LAB area00light area01light "lightTypeRaw ==")
  local p
  for p in "${phrases[@]}"; do
    if grep -Fq "$p" "$path"; then
      violation "$path contains target-specific phrase: $p"
    fi
  done
}

check_target_specific() {
  local modules=(
    "libs/nds/src/nitro/g3d/Nsbmd.lua"
    "romdump/src/digest/model/MaterialCompiler.lua"
    "romdump/src/digest/model/MeshCompiler.lua"
    "libs/nds/src/love/GxRenderer.lua"
    "libs/nds/src/love/shaders/map.glsl"
  )
  local m
  for m in "${modules[@]}"; do
    if [ ! -r "$m" ]; then
      violation "core module missing or unreadable: $m"
      continue
    fi
    check_forbidden_phrases "$m"
  done
}

# Check B — terminal output from game/runtime source. The bare-print rule
# mirrors the Lua contract: `print(` not preceded by an identifier character,
# '_', '.', or ':' (line-start counts as unpreceded; a line-based grep is
# exactly equivalent to the whole-file pattern).
check_terminal_output_file() {
  local path="$1"
  if grep -Fq "io.stderr" "$path"; then
    violation "$path must not write to stderr"
  fi
  if grep -Fq "io.stdout" "$path"; then
    violation "$path must not write to stdout"
  fi
  if grep -Eq '(^|[^A-Za-z0-9_.:])print\(' "$path"; then
    violation "$path must not call global print"
  fi
}

is_first_party_lua() {
  local path="$1"
  if [[ "$path" =~ ^app/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^game/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^gen4/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^libs/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^romdump/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^scripts/.*\.lua$ ]]; then
    return 0
  fi
  if [[ "$path" =~ ^tests/.*\.lua$ ]]; then
    return 0
  fi
  return 1
}

# Scope predicates mirror scripts/ci/source_scope.py: any path with a tests
# segment is test scope. Explicit absolute paths default to production while
# tracked paths additionally require a production root. Production annotation
# rules apply only to production scope; diagnostic directives are rejected
# everywhere except the single narrow test-only form.
policy_scope_for_path() {
  local path="$1"
  if [[ "$path" == *"/tests/"* ]] || [[ "$path" == tests/* ]]; then
    echo "test"
  elif [[ "$path" == /* ]] && [[ "$path" == *.lua ]]; then
    echo "production"
  elif [[ "$path" =~ ^(app|game|gen4|libs|romdump)/.*\.lua$ ]]; then
    echo "production"
  else
    echo "other"
  fi
}

# Diagnostic directives: production and other non-test sources allow none;
# tests allow only the exact next-line param-type-mismatch suppression.
check_diagnostic_directive_file() {
  local path="$1"
  local scope="$2"
  local line
  local lineno=0
  local narrow_re='^[[:space:]]*---@diagnostic[[:space:]]+disable-next-line:[[:space:]]*param-type-mismatch([[:space:]]+--.*)?$'
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ "$line" == *"---@diagnostic"* ]] || continue
    if [ "$scope" = "test" ] && [[ "$line" =~ $narrow_re ]]; then
      continue
    fi
    violation "$path:$lineno: diagnostic directive not allowed in $scope scope; tests may only use disable-next-line: param-type-mismatch"
  done < "$path"
  return 0
}

# Production annotation policy: reject the standalone token `any` on
# LuaCATS/inline-assertion lines (deliberately including prose occurrences on
# those lines), and reject bare `table` at leading type-start and type
# punctuation positions unless shaped as table<...> or table[...].
check_production_annotation_policy_file() {
  local path="$1"
  local line
  local lineno=0
  local any_re='(^|[^A-Za-z0-9_])any([^A-Za-z0-9_]|$)'
  local bare_table_re='(^|[^A-Za-z0-9_])table([^A-Za-z0-9_<\[]|$)'
  local type_start_re='^[[:space:]]*---@((param[[:space:]]+[^[:space:]]+[[:space:]]+)|(return[[:space:]]+)|(type[[:space:]]+)|(field[[:space:]]+(public[[:space:]]+|private[[:space:]]+|protected[[:space:]]+)?(\[[^]]*\][[:space:]]*|[^[:space:]]+[[:space:]]+))|(alias[[:space:]]+[^[:space:]]+[[:space:]]+)|(vararg[[:space:]]+)|(cast[[:space:]]+[^[:space:]]+[[:space:]]+))table([^A-Za-z0-9_<\[]|$)'
  local continuation_re='^[[:space:]]*---@.*[|&,(:\[][[:space:]]*table([^A-Za-z0-9_<\[]|$)'
  local alias_continuation_re='^[[:space:]]*---\|'
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ "$line" == *"---@diagnostic"* ]] && continue
    [[ "$line" == *"---@"* ]] || [[ "$line" == *"@as"* ]] || continue
    if [[ "$line" =~ $any_re ]]; then
      violation "$path:$lineno: production annotation uses explicit any; use a named or shaped contract"
    fi
    if [[ "$line" =~ $type_start_re ]] || [[ "$line" =~ $continuation_re ]]; then
      violation "$path:$lineno: production annotation uses bare table; use a shaped or named contract"
    elif [[ "$line" =~ $alias_continuation_re ]] && [[ "$line" =~ $bare_table_re ]]; then
      violation "$path:$lineno: production annotation uses bare table; use a shaped or named contract"
    fi
  done < "$path"
  return 0
}

# .luarc.json owns the single global diagnostic allowance. Any additional
# diagnostic-off switch is a violation.
check_luarc_policy() {
  local luarc=".luarc.json"
  if [ ! -r "$luarc" ]; then
    violation ".luarc.json is missing or unreadable"
    return 0
  fi
  local disable_count
  disable_count="$(grep -o -F '"disable"' "$luarc" | wc -l || true)"
  disable_count="$(echo "$disable_count" | tr -d '[:space:]')"
  if [ "$disable_count" != "1" ]; then
    violation ".luarc.json must define exactly one diagnostics.disable entry"
  fi
  if ! grep -Eq '"disable"[[:space:]]*:[[:space:]]*\["duplicate-set-field"\]' "$luarc"; then
    violation '.luarc.json must disable exactly ["duplicate-set-field"] globally'
  fi
  if grep -Fq '"Ignore' "$luarc"; then
    violation ".luarc.json must not silence diagnostics with Ignore"
  fi
  if grep -Fq '"None' "$luarc"; then
    violation ".luarc.json must not silence diagnostics with None"
  fi
  if grep -Eq '"enable"[[:space:]]*:[[:space:]]*false' "$luarc"; then
    violation ".luarc.json must not disable diagnostics with enable: false"
  fi
  if grep -Fq 'disableScheme' "$luarc"; then
    violation ".luarc.json must not use disableScheme"
  fi
  if grep -Fq 'await-in-sync' "$luarc"; then
    violation ".luarc.json must not opt await-in-sync into file diagnostics"
  fi
  return 0
}

check_tracked_scope() {
  local tracked
  tracked="$(git ls-files 2>/dev/null)" || return 0
  [ -n "$tracked" ] || return 0
  local line
  local scope
  while IFS= read -r line; do
    if [[ "$line" =~ \.lua$ ]] && is_first_party_lua "$line"; then
      [ -r "$line" ] || continue
      scope="$(policy_scope_for_path "$line")"
      if [ "$scope" = "test" ]; then
        check_diagnostic_directive_file "$line" "test"
      elif [ "$scope" = "production" ]; then
        check_diagnostic_directive_file "$line" "production"
        check_production_annotation_policy_file "$line"
      else
        check_diagnostic_directive_file "$line" "production"
      fi
    fi
    if [[ "$line" =~ ^game/src/.*\.lua$ ]] || [[ "$line" =~ ^game/hgss/src/.*\.lua$ ]] || [[ "$line" =~ ^libs/[^/]+/src/.*\.lua$ ]] || [[ "$line" =~ ^romdump/src/.*\.lua$ ]]; then
      # A tracked file deleted from the working tree (a pending deletion)
      # has no source content to scan.
      [ -r "$line" ] || continue
      if [[ "$line" =~ ^game/src/.*\.lua$ ]] || [[ "$line" =~ ^game/hgss/src/.*\.lua$ ]] || [[ "$line" =~ ^libs/[^/]+/src/.*\.lua$ ]]; then
        check_terminal_output_file "$line"
      fi
      if check_assigned_or_returned_anonymous_function_file "$line"; then
        violation "$line uses an assigned or directly returned anonymous function form; name the function"
      fi
    fi
  done <<< "$tracked"
}

check_target_specific

if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    [ -r "$path" ] || { violation "cannot read: $path"; continue; }
    check_forbidden_phrases "$path"
    check_terminal_output_file "$path"
    if check_assigned_or_returned_anonymous_function_file "$path"; then
      violation "$path uses an assigned or directly returned anonymous function form; name the function"
    fi
    if [[ "$path" =~ \.lua$ ]]; then
      scope="$(policy_scope_for_path "$path")"
      if [ "$scope" = "test" ]; then
        check_diagnostic_directive_file "$path" "test"
      else
        check_diagnostic_directive_file "$path" "production"
        if [ "$scope" = "production" ]; then
          check_production_annotation_policy_file "$path"
        fi
      fi
    fi
  done
else
  check_luarc_policy
  check_tracked_scope
fi

exit "$fail"
