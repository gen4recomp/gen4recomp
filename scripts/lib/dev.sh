# Shared script setup. Source after cd-ing to the repo root.
#
# Load the local dev env (.envrc) if present, then apply the single app-level
# save-directory override, PORTEMON_SAVE_DIR, onto the variable LÖVE/PhysFS reads
# for its save-dir base. This is the one seam a future portable mode will reuse;
# when PORTEMON_SAVE_DIR is unset, LÖVE uses the OS default per-user location.
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
  hooks_path=""
  if hooks_path="$(git config --local --get core.hooksPath 2>/dev/null)"; then
    :
  else
    config_status="$?"
    if [ "$config_status" -ne 1 ]; then
      exit "$config_status"
    fi
  fi
  if [ "$hooks_path" != "scripts/hooks" ]; then
    scripts/lib/repo-setup.sh
  fi
fi

[ -f .envrc ] && source .envrc

if [ -n "${PORTEMON_SAVE_DIR:-}" ]; then
  case "$(uname -s)" in
    # Linux/BSD: PhysFS derives the save-dir base from XDG_DATA_HOME.
    Linux|*BSD) export XDG_DATA_HOME="$PORTEMON_SAVE_DIR" ;;
    # macOS/Windows use fixed appdata roots; wire their overrides in when
    # portable mode lands. For now this keeps dev on those platforms explicit.
    *) export XDG_DATA_HOME="$PORTEMON_SAVE_DIR" ;;
  esac
fi
