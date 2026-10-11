#!/usr/bin/env bash
# ==============================================================================
# scripts/update.sh — Claude Code Orchestra Template Updater
#
# Fetches the latest version of the claude-code-orchestra template and safely
# updates local files. Template-owned content lives under .claude/ (plus the
# .agents/ and .codex/ adapters); mutable project context is preserved in
# .claude/STATE.md and .claude/docs/.
#
# Usage:
#   ./scripts/update.sh                # Update to the default branch
#   ./scripts/update.sh <branch|tag>   # Update to a specific branch or tag
#   ./scripts/update.sh --yes          # Skip confirmation prompts
#
# Template source, first match wins:
#   1. ORCHESTRA_TEMPLATE_REPO environment variable
#   2. .claude/orchestra-source (recorded by scripts/install.sh)
#   3. https://github.com/Yuulis/claude-code-orchestra.git
# ==============================================================================
set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
DEFAULT_TEMPLATE_REPO="https://github.com/Yuulis/claude-code-orchestra.git"
TEMPLATE_REPO=""
TEMPLATE_REPO_ORIGIN=""
LOCAL_VERSION_FILE=".claude/orchestra-version"
SOURCE_FILE=".claude/orchestra-source"
# Top-level entries of each SAFE_DIR that the template installed last time.
# Only entries listed here may be removed when the template stops shipping
# them; every other entry is project-owned and kept.
MANIFEST_FILE=".claude/orchestra-manifest"
TEMPLATE_BOUNDARY="@orchestra:template-boundary"
REPO_BOUNDARY="@orchestra:repo-boundary"
LEGACY_BOUNDARY="@orchestra:local-boundary"
BOUNDARY_LINE="# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Template-owned directories, merged entry by entry (see sync_safe_dirs):
# entries the template ships are replaced, project-owned entries are kept.
SAFE_DIRS=(
    ".claude/rules"
    ".claude/skills"
    ".claude/agents"
    ".claude/hooks"
    ".agents/skills"
)
# Files that no SAFE_DIR already covers. `.claude/rules/`, `.claude/skills/`,
# above are merged as directories, so their contents must not be repeated here.
SAFE_FILES=(
    "AGENTS.md"
    ".agents/AGENTS.md"
    ".codex/AGENTS.md"
    ".claude/statusline.py"
    ".claude/docs/INDEX.md"
    ".claude/docs/change_main.md"
    ".claude/docs/CODEX_HANDOFF_PLAYBOOK.md"
    ".claude/docs/libraries/.gitkeep"
    ".claude/docs/plans/.gitkeep"
    ".claude/docs/reviews/.gitkeep"
    "scripts/check.sh"
    "scripts/install.sh"
    "scripts/update.sh"
)

# Paths that previous template versions installed but no longer ship.
# The updater removes these from the local project so that orphans from
# deprecated features (e.g. removed CLI integrations) don't linger.
#
# When you remove an entry from SAFE_DIRS or SAFE_FILES, add the old path
# here so existing projects get cleaned up on their next update.
# Each entry MUST start with "." (a dotfile/dot-dir) to keep the blast
# radius scoped to template-owned locations.
DEPRECATED_PATHS=(
    ".gemini"
    ".agents/workflows"
    ".agents/rules"
    ".agents/agents"
    ".agents/hooks"
    ".codex/skills"
)

# Project-owned data that pre-2.0 installations kept under .agents/. It is
# moved to .claude/ rather than removed: these directories hold the project's
# own design docs, logs, and checkpoints, not template content.
LEGACY_PROJECT_DIRS=(
    "docs"
    "logs"
    "checkpoints"
)

# Same entries scripts/install.sh writes: the shipped scripts keep LF endings
# in every clone of the project, even with core.autocrlf=true. Installs made
# before these entries existed get them on their next update.
GITATTRIBUTES_ENTRIES=(
    "scripts/check.sh text eol=lf"
    "scripts/install.sh text eol=lf"
    "scripts/update.sh text eol=lf"
    ".claude/** text=auto eol=lf"
    ".agents/** text=auto eol=lf"
    ".codex/** text=auto eol=lf"
)

# Machine-readable native settings: never overwritten, shown as a diff only.
# A downstream project edits its model, approval policy, and hooks here.
SETTINGS_FILES=(
    ".claude/settings.json"
    ".codex/config.toml"
)

# =============================================================================
# Color output (with fallback for non-color terminals)
# =============================================================================
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RED=$(tput setaf 1)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    GREEN=""
    YELLOW=""
    RED=""
    BOLD=""
    RESET=""
fi

# =============================================================================
# Utility functions
# =============================================================================
info()    { echo "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo ""; echo "${BOLD}━━━ $* ━━━${RESET}"; }

TMPDIR_UPDATE=""
UPDATED_FILES=()
AUTO_YES=false
TARGET_REF=""
SELF_UPDATED=false
# Created on first use; everything the update replaces or removes is copied
# here first, so no project content is lost to an update.
BACKUP_ROOT=""
BACKED_UP_COUNT=0
KEPT_ENTRIES=()
# Newline-separated entries of the previous manifest; HAVE_MANIFEST is false
# for installations that predate it.
PREVIOUS_MANIFEST=""
HAVE_MANIFEST=false

# In-flight stage-and-swap tracking (see sync_safe_dirs). At most one
# SAFE_DIR is mid-transition at a time since the loop is sequential; the
# trap below inspects these to roll back a crash cleanly.
CURRENT_STAGING_DIR=""
CURRENT_OLD_DIR=""
CURRENT_LIVE_DIR=""
SWAP_IN_PROGRESS=false

cleanup() {
    # Roll back a stage-and-swap that was interrupted mid-transition: the
    # live directory has already been renamed to CURRENT_OLD_DIR but the
    # staged replacement has not yet been moved into place. Restore the
    # original so the target repo is never left without the directory.
    if [[ "${SWAP_IN_PROGRESS}" == true && -n "${CURRENT_OLD_DIR}" ]] &&
        [[ -e "${CURRENT_OLD_DIR}" || -L "${CURRENT_OLD_DIR}" ]]; then
        rm -rf "${CURRENT_LIVE_DIR}"
        mv "${CURRENT_OLD_DIR}" "${CURRENT_LIVE_DIR}"
    fi
    # Remove any leftover staging directory (either the swap never started,
    # or it already completed and this is just belt-and-suspenders).
    if [[ -n "${CURRENT_STAGING_DIR}" && -d "${CURRENT_STAGING_DIR}" ]]; then
        rm -rf "${CURRENT_STAGING_DIR}"
    fi
    # Remove a leftover .orchestra-old.$$ if the swap completed but cleanup
    # of the old copy was interrupted.
    if [[ -n "${CURRENT_OLD_DIR}" ]] && [[ -e "${CURRENT_OLD_DIR}" || -L "${CURRENT_OLD_DIR}" ]]; then
        rm -rf "${CURRENT_OLD_DIR}"
    fi

    if [[ -n "${TMPDIR_UPDATE}" && -d "${TMPDIR_UPDATE}" ]]; then
        rm -rf "${TMPDIR_UPDATE}"
    fi
}
trap cleanup EXIT INT TERM

# =============================================================================
# Parse arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS] [VERSION_REF]"
                echo ""
                echo "Options:"
                echo "  -y, --yes    Skip confirmation prompts"
                echo "  -h, --help   Show this help message"
                echo ""
                echo "Arguments:"
                echo "  VERSION_REF  Branch or tag to fetch. Default: the template's default branch"
                echo ""
                echo "Template source (first match wins):"
                echo "  1. ORCHESTRA_TEMPLATE_REPO environment variable"
                echo "  2. ${SOURCE_FILE} (recorded by scripts/install.sh)"
                echo "  3. ${DEFAULT_TEMPLATE_REPO}"
                echo ""
                echo "Template-owned directories are merged entry by entry: project-owned"
                echo "skills, agents, rules, and hooks are kept, and anything replaced or"
                echo "removed is backed up under .orchestra-backup-update-*/."
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                exit 1
                ;;
            *)
                TARGET_REF="$1"
                shift
                ;;
        esac
    done
}

# =============================================================================
# Phase 1: Pre-flight checks
# =============================================================================
preflight_checks() {
    header "Pre-flight Checks"

    # Verify we are in a git repo
    if ! git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
        error "Not inside a git repository. Run this script from within your project."
        exit 1
    fi
    info "Git repository detected."

    # Check for uncommitted changes
    if ! git -C "${PROJECT_ROOT}" diff --quiet || ! git -C "${PROJECT_ROOT}" diff --cached --quiet; then
        warn "You have uncommitted changes."
        if [[ "${AUTO_YES}" == false ]]; then
            read -r -p "${YELLOW}Continue anyway? [y/N]${RESET} " response
            case "${response}" in
                [yY][eE][sS]|[yY]) ;;
                *)
                    info "Aborted. Please commit or stash your changes first."
                    exit 0
                    ;;
            esac
        else
            warn "Proceeding despite uncommitted changes (--yes flag)."
        fi
    else
        info "Working tree is clean."
    fi

    # Check for untracked files in paths we will overwrite
    local untracked
    untracked="$(git -C "${PROJECT_ROOT}" ls-files --others --exclude-standard 2>/dev/null || true)"
    if [[ -n "${untracked}" ]]; then
        warn "There are untracked files in the repository."
    fi

    resolve_template_repo

    # Read the installed Orchestra version. The repository's root VERSION,
    # when present, belongs to the downstream project and is never touched.
    if [[ -f "${PROJECT_ROOT}/${LOCAL_VERSION_FILE}" ]]; then
        OLD_VERSION="$(tr -d '[:space:]' < "${PROJECT_ROOT}/${LOCAL_VERSION_FILE}")"
        info "Current version: ${BOLD}${OLD_VERSION}${RESET}"
    else
        OLD_VERSION="(none)"
        warn "No ${LOCAL_VERSION_FILE} found. This may be a first-time setup."
    fi
}

# The recorded source is a committed file, so a change to it is a change to
# where executable hooks come from: it is shown before anything is fetched.
resolve_template_repo() {
    local recorded=""
    if [[ -f "${PROJECT_ROOT}/${SOURCE_FILE}" ]]; then
        recorded="$(head -n 1 "${PROJECT_ROOT}/${SOURCE_FILE}" | tr -d '[:space:]')"
    fi

    if [[ -n "${ORCHESTRA_TEMPLATE_REPO:-}" ]]; then
        TEMPLATE_REPO="${ORCHESTRA_TEMPLATE_REPO}"
        TEMPLATE_REPO_ORIGIN="ORCHESTRA_TEMPLATE_REPO"
    elif [[ -n "${recorded}" ]]; then
        TEMPLATE_REPO="${recorded}"
        TEMPLATE_REPO_ORIGIN="${SOURCE_FILE}"
    else
        TEMPLATE_REPO="${DEFAULT_TEMPLATE_REPO}"
        TEMPLATE_REPO_ORIGIN="default"
    fi

    if [[ "${TEMPLATE_REPO}" == -* ]]; then
        error "Refusing template source that starts with '-': ${TEMPLATE_REPO}"
        exit 1
    fi
    info "Template source: ${BOLD}${TEMPLATE_REPO}${RESET} (${TEMPLATE_REPO_ORIGIN})"
    if [[ "${TEMPLATE_REPO_ORIGIN}" == "${SOURCE_FILE}" && "${TEMPLATE_REPO}" != "${DEFAULT_TEMPLATE_REPO}" ]]; then
        warn "This differs from ${DEFAULT_TEMPLATE_REPO}; the update installs hooks"
        warn "that Claude Code executes, so only continue if you trust that repository."
    fi
}

# =============================================================================
# Phase 2: Fetch latest template
# =============================================================================
fetch_template() {
    header "Fetching Template"

    TMPDIR_UPDATE="$(mktemp -d)"
    info "Cloning template to temporary directory..."

    local clone_args=(--depth 1)
    if [[ -n "${TARGET_REF}" ]]; then
        clone_args+=(--branch "${TARGET_REF}")
        info "Target ref: ${BOLD}${TARGET_REF}${RESET}"
    fi

    # core.autocrlf=false: a CRLF checkout of the template would install
    # scripts whose "#!/usr/bin/env bash\r" line no longer runs, including the
    # updater itself. Template versions with .gitattributes force LF anyway.
    clone_args+=(-c core.autocrlf=false)

    if ! git clone "${clone_args[@]}" -- "${TEMPLATE_REPO}" "${TMPDIR_UPDATE}/template" 2>&1 | tail -1; then
        error "Failed to clone template repository."
        error "URL: ${TEMPLATE_REPO}"
        if [[ -n "${TARGET_REF}" ]]; then
            error "Ref: ${TARGET_REF}"
        fi
        exit 1
    fi

    TEMPLATE_DIR="${TMPDIR_UPDATE}/template"

    # Read new VERSION
    if [[ -f "${TEMPLATE_DIR}/VERSION" ]]; then
        NEW_VERSION="$(cat "${TEMPLATE_DIR}/VERSION" | tr -d '[:space:]')"
    else
        NEW_VERSION="(unknown)"
        warn "Template does not contain a VERSION file."
    fi

    info "Version: ${BOLD}${OLD_VERSION}${RESET} -> ${BOLD}${NEW_VERSION}${RESET}"
}

# =============================================================================
# Phase 2.5: Remove deprecated paths (orphans from older template versions)
# =============================================================================
# Runs BEFORE sync_safe_dirs so future deprecations that overlap with new
# SAFE_DIRS don't fight rsync. Each entry is validated against several
# defense-in-depth checks before `rm -rf` to prevent foot-guns.
cleanup_deprecated_paths() {
    header "Cleaning Up Deprecated Paths"

    if [[ ${#DEPRECATED_PATHS[@]} -eq 0 ]]; then
        info "No deprecated paths configured."
        return 0
    fi

    local project_root_abs
    project_root_abs="$(cd "${PROJECT_ROOT}" && pwd -P)"

    for path in "${DEPRECATED_PATHS[@]}"; do
        local trimmed="${path//[[:space:]]/}"
        if [[ -z "${trimmed}" ]]; then
            warn "Skipping empty DEPRECATED_PATHS entry."
            continue
        fi
        if [[ "${path}" == "." || "${path}" == "./" ]]; then
            error "Refusing to remove '.' (would target project root). Skipping."
            continue
        fi
        if [[ "${path:0:1}" != "." ]]; then
            error "DEPRECATED_PATHS entry must start with '.': '${path}'. Skipping."
            continue
        fi
        if [[ "${path}" == /* ]]; then
            error "DEPRECATED_PATHS entry must be relative: '${path}'. Skipping."
            continue
        fi
        # Substring catches '.foo/../../etc' as well as leading '..'
        if [[ "${path}" == *".."* ]]; then
            error "DEPRECATED_PATHS entry contains '..': '${path}'. Skipping."
            continue
        fi

        local target="${PROJECT_ROOT}/${path}"

        if [[ ! -e "${target}" && ! -L "${target}" ]]; then
            continue
        fi

        # Escape check: resolve symlinks in parent components and ensure
        # the final target is still strictly inside PROJECT_ROOT.
        local resolved
        resolved="$(realpath -m -- "${target}")"
        if [[ "${resolved}" != "${project_root_abs}/"* ]]; then
            error "Refusing to remove '${path}': resolves outside PROJECT_ROOT (${resolved})."
            continue
        fi
        if [[ "${resolved}" == "${project_root_abs}" ]]; then
            error "Refusing to remove '${path}': resolves to PROJECT_ROOT itself."
            continue
        fi

        warn "Removing deprecated path: ${path} (backed up first)"
        backup_path "${path}"
        if git -C "${PROJECT_ROOT}" ls-files --error-unmatch -- "${path}" &>/dev/null; then
            git -C "${PROJECT_ROOT}" rm -rf --quiet --ignore-unmatch -- "${path}" \
                || rm -rf -- "${target}"
        else
            rm -rf -- "${target}"
        fi
        UPDATED_FILES+=("REMOVED: ${path}")
    done
}

migrate_legacy_native_data() {
    header "Migrating Legacy Project Data"

    local name legacy canonical backup_root=""
    for name in "${LEGACY_PROJECT_DIRS[@]}"; do
        legacy="${PROJECT_ROOT}/.agents/${name}"
        canonical="${PROJECT_ROOT}/.claude/${name}"
        if [[ ! -d "${legacy}" || -L "${legacy}" ]]; then
            continue
        fi

        if [[ ! -e "${canonical}" ]] ||
            [[ -d "${canonical}" && -z "$(find "${canonical}" -mindepth 1 -print -quit)" ]]; then
            rm -rf -- "${canonical}"
            mkdir -p "$(dirname "${canonical}")"
            mv -- "${legacy}" "${canonical}"
            UPDATED_FILES+=(".claude/${name} (migrated from .agents/${name})")
            continue
        fi

        if [[ -z "${backup_root}" ]]; then
            backup_root="${PROJECT_ROOT}/.orchestra-backup-native-migration-$(date +%Y%m%d%H%M%S)-$$"
        fi
        mkdir -p "${backup_root}/.agents" "${canonical}"
        cp -a -- "${legacy}" "${backup_root}/.agents/${name}"
        cp -an -- "${legacy}/." "${canonical}/"
        rm -rf -- "${legacy}"
        UPDATED_FILES+=(".claude/${name} (merged from .agents/${name})")
    done

    # Shared state is a single file, not a directory, but has the same
    # project-owned character: never drop it, move it if .claude/ has none.
    local legacy_state="${PROJECT_ROOT}/.agents/STATE.md"
    local canonical_state="${PROJECT_ROOT}/.claude/STATE.md"
    if [[ -f "${legacy_state}" && ! -L "${legacy_state}" ]]; then
        mkdir -p "${PROJECT_ROOT}/.claude"
        if [[ ! -e "${canonical_state}" ]]; then
            mv -- "${legacy_state}" "${canonical_state}"
            UPDATED_FILES+=(".claude/STATE.md (migrated from .agents/STATE.md)")
        else
            if [[ -z "${backup_root}" ]]; then
                backup_root="${PROJECT_ROOT}/.orchestra-backup-native-migration-$(date +%Y%m%d%H%M%S)-$$"
            fi
            mkdir -p "${backup_root}/.agents"
            cp -a -- "${legacy_state}" "${backup_root}/.agents/STATE.md"
            rm -f -- "${legacy_state}"
            warn "Both .agents/STATE.md and .claude/STATE.md existed; kept .claude/STATE.md."
        fi
    fi

    if [[ -n "${backup_root}" ]]; then
        warn "Legacy project data was backed up before merging: ${backup_root}"
    fi
}

# =============================================================================
# Phase 3: Safe files (full overwrite)
# =============================================================================
# Stage-and-swap keeps a crash (Ctrl-C, power loss, copy failure) from ever
# leaving a SAFE_DIR half-updated. Each directory is staged and swapped
# independently: a mid-run interruption may leave later SAFE_DIRS un-synced
# (the update is simply incomplete and re-runnable), but it can never corrupt
# a directory that was in flight. The staging/old siblings live inside the
# target repo (same filesystem as the destination) so the final `mv` swaps
# are atomic renames, not copies.
sync_safe_dirs() {
    header "Updating Safe Directories"

    load_previous_manifest
    for dir in "${SAFE_DIRS[@]}"; do
        local src="${TEMPLATE_DIR}/${dir}"
        local dst="${PROJECT_ROOT}/${dir}"

        if [[ ! -d "${src}" ]]; then
            warn "Template does not contain ${dir}/, skipping."
            continue
        fi

        local staging="${dst}.orchestra-staging.$$"
        local old="${dst}.orchestra-old.$$"
        rm -rf "${staging}" "${old}"
        mkdir -p "${staging}"

        # Track in-flight state so the EXIT/INT/TERM trap can roll back if
        # anything below fails or the process is interrupted.
        CURRENT_STAGING_DIR="${staging}"
        CURRENT_OLD_DIR="${old}"
        CURRENT_LIVE_DIR="${dst}"
        SWAP_IN_PROGRESS=false

        # `cp -a` rather than rsync: rsync is absent from minimal images
        # (containers, CI runners), where the updater died with exit 127
        # partway through; cp ships with coreutils everywhere. Copying entry
        # by entry preserves symlinks and dotfiles.
        local shipped name
        shipped="$(list_entries "${src}")" || exit 1
        while IFS= read -r name; do
            [[ -n "${name}" ]] || continue
            cp -a "${src}/${name}" "${staging}/${name}"
        done <<< "${shipped}"
        stage_local_entries "${dir}" "${shipped}" "${staging}"

        if [[ -e "${dst}" || -L "${dst}" ]]; then
            SWAP_IN_PROGRESS=true
            mv "${dst}" "${old}"
            mv "${staging}" "${dst}"
            SWAP_IN_PROGRESS=false
            rm -rf "${old}"
        else
            mkdir -p "$(dirname "${dst}")"
            mv "${staging}" "${dst}"
        fi

        # Swap completed; clear in-flight tracking so the trap is a no-op
        # for this directory.
        CURRENT_STAGING_DIR=""
        CURRENT_OLD_DIR=""
        CURRENT_LIVE_DIR=""

        info "Synced ${dir}/"
        UPDATED_FILES+=("${dir}/")
    done
    write_manifest
}

# Decides, for every entry already in the live directory, whether it survives
# the swap. Template entries are replaced (the local copy is backed up when it
# differs); entries the previous manifest listed but the template dropped are
# backed up and removed; everything else is project-owned and copied into the
# staging directory so the swap keeps it.
stage_local_entries() {
    local dir="$1" shipped="$2" staging="$3"
    local dst="${PROJECT_ROOT}/${dir}" name existing

    if [[ -L "${dst}" || ( -e "${dst}" && ! -d "${dst}" ) ]]; then
        backup_path "${dir}"
        return 0
    fi
    [[ -d "${dst}" ]] || return 0

    existing="$(list_entries "${dst}")" || exit 1
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        if list_contains "${shipped}" "${name}"; then
            if entries_differ "${dst}/${name}" "${TEMPLATE_DIR}/${dir}/${name}"; then
                backup_path "${dir}/${name}"
            fi
        elif list_contains "${PREVIOUS_MANIFEST}" "${dir}/${name}"; then
            backup_path "${dir}/${name}"
            UPDATED_FILES+=("REMOVED: ${dir}/${name} (dropped by the template)")
        elif is_stale_codex_skill_copy "${dir}" "${dst}/${name}" "${name}"; then
            backup_path "${dir}/${name}"
            UPDATED_FILES+=("REMOVED: ${dir}/${name} (stale pre-2.0 copy)")
        else
            cp -a "${dst}/${name}" "${staging}/${name}"
            KEPT_ENTRIES+=("${dir}/${name}")
        fi
    done <<< "${existing}"
}

# Pre-2.0 installs kept real copies of the template skills in .agents/skills/.
# Every template entry there is now a link into .claude/skills/, so a real
# directory named after a template skill is a stale copy, not project content.
is_stale_codex_skill_copy() {
    local dir="$1" path="$2" name="$3"
    [[ "${dir}" == ".agents/skills" && -d "${path}" && ! -L "${path}" ]] || return 1
    [[ -e "${TEMPLATE_DIR}/.claude/skills/${name}" ]]
}

# Succeeds when two entries differ. Symlinks compare by target; bytecode
# caches never count as a difference.
entries_differ() {
    local local_path="$1" template_path="$2"
    if [[ -L "${local_path}" || -L "${template_path}" ]]; then
        [[ -L "${local_path}" && -L "${template_path}" &&
            "$(readlink "${local_path}")" == "$(readlink "${template_path}")" ]] && return 1
        return 0
    fi
    ! diff -rq -x __pycache__ --no-dereference -- "${local_path}" "${template_path}" &>/dev/null
}

# Copies a project path (relative to PROJECT_ROOT) into the update's backup
# directory, creating the directory on first use.
backup_path() {
    local path="$1"
    if [[ -z "${BACKUP_ROOT}" ]]; then
        BACKUP_ROOT="${PROJECT_ROOT}/.orchestra-backup-update-$(date +%Y%m%d%H%M%S)-$$"
        mkdir -p "${BACKUP_ROOT}"
    fi
    mkdir -p "${BACKUP_ROOT}/$(dirname "${path}")"
    cp -a "${PROJECT_ROOT}/${path}" "${BACKUP_ROOT}/${path}"
    BACKED_UP_COUNT=$((BACKED_UP_COUNT + 1))
}

# Prints the top-level entry names of a directory, dotfiles included, skipping
# bytecode caches, which are generated locally and never template content.
# Fails -- rather than printing nothing -- when the directory cannot be listed
# or holds a name with a newline, which the line-based lists cannot represent:
# an empty listing would otherwise read as "nothing to keep".
list_entries() {
    local dir="$1" names name
    [[ -d "${dir}" ]] || return 0
    if [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -name $'*\n*' -print -quit)" ]]; then
        error "An entry name in ${dir} contains a newline; rename it and re-run."
        return 1
    fi
    names="$(ls -A -- "${dir}")" || return 1
    [[ -n "${names}" ]] || return 0
    while IFS= read -r name; do
        [[ "${name}" == "__pycache__" ]] || printf '%s\n' "${name}"
    done <<< "${names}" | sort
}

# Succeeds when the newline-separated list in $1 contains the line $2.
list_contains() {
    [[ -n "$1" ]] && grep -Fqx -- "$2" <<< "$1"
}

load_previous_manifest() {
    local manifest="${PROJECT_ROOT}/${MANIFEST_FILE}"
    if [[ ! -f "${manifest}" ]]; then
        warn "No ${MANIFEST_FILE} found (installed before 1.1.0): entries the template"
        warn "does not ship are kept, including ones an older template version installed."
        return 0
    fi
    PREVIOUS_MANIFEST="$(grep -v '^#' "${manifest}" || true)"
    HAVE_MANIFEST=true
}

write_manifest() {
    local destination="${PROJECT_ROOT}/${MANIFEST_FILE}"
    local dir name entries=""
    mkdir -p "$(dirname "${destination}")"
    for dir in "${SAFE_DIRS[@]}"; do
        if [[ -d "${TEMPLATE_DIR}/${dir}" ]]; then
            entries+="$(list_entries "${TEMPLATE_DIR}/${dir}" | sed "s#^#${dir}/#")" || exit 1
        else
            # The directory was skipped, not synced: keep its ownership record
            # so the entries are still recognised as template content later.
            entries+="$(awk -v prefix="${dir}/" 'index($0, prefix) == 1' <<< "${PREVIOUS_MANIFEST}")"
        fi
        entries+=$'\n'
    done
    {
        echo "# Claude Code Orchestra: template-owned entries written by scripts/install.sh"
        echo "# or scripts/update.sh. Entries missing from this list are project-owned and"
        echo "# are never removed by scripts/update.sh. Do not edit by hand."
        while IFS= read -r name; do
            [[ -z "${name}" ]] || echo "${name}"
        done <<< "${entries}"
    } > "${destination}.tmp.$$"
    mv -f "${destination}.tmp.$$" "${destination}"
    UPDATED_FILES+=("${MANIFEST_FILE}")
}

sync_safe_files() {
    header "Updating Safe Files"

    for file in "${SAFE_FILES[@]}"; do
        local src="${TEMPLATE_DIR}/${file}"
        local dst="${PROJECT_ROOT}/${file}"

        if [[ ! -f "${src}" ]]; then
            warn "Template does not contain ${file}, skipping."
            continue
        fi

        mkdir -p "$(dirname "${dst}")"
        if [[ "${file}" == "scripts/update.sh" && -f "${dst}" ]] \
            && ! cmp -s "${src}" "${dst}"; then
            SELF_UPDATED=true
        fi
        # Local edits to a template file are kept in the backup, not lost.
        if [[ -e "${dst}" || -L "${dst}" ]] && ! cmp -s "${src}" "${dst}"; then
            backup_path "${file}"
        fi
        # Copy via temp + mv: an atomic rename gives the destination a new
        # inode, so the running update.sh keeps reading its original file
        # instead of a half-overwritten one (self-update safety).
        cp -f "${src}" "${dst}.tmp.$$"
        mv -f "${dst}.tmp.$$" "${dst}"
        info "Updated ${file}"
        UPDATED_FILES+=("${file}")
    done

    # Ensure scripts/update.sh stays executable after self-update
    if [[ -f "${PROJECT_ROOT}/scripts/update.sh" ]]; then
        chmod +x "${PROJECT_ROOT}/scripts/update.sh"
    fi
}

# =============================================================================
# Phase 4: Legacy state migration
# =============================================================================
#
# Current releases keep AGENTS.md immutable and store mutable context in
# .claude/STATE.md. Boundary helpers remain only to migrate older 2/3-zone
# AGENTS.md or CLAUDE.md files before AGENTS.md is overwritten and CLAUDE.md is
# moved aside.

# Strip leading blank or ━ separator lines from stdin
_strip_leading_frame() {
    awk '
    started == 0 {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^# ━/) next
        started = 1
    }
    started { print }'
}

# Strip trailing blank or ━ separator lines from stdin
_strip_trailing_frame() {
    awk '
    { buf[NR] = $0 }
    END {
        last = NR
        while (last > 0 && (buf[last] ~ /^[[:space:]]*$/ || buf[last] ~ /^# ━/)) last--
        for (i = 1; i <= last; i++) print buf[i]
    }'
}

# Print content above the first line matching the given marker, with trailing frame stripped
_extract_zone_above() {
    local file="$1"
    local marker="$2"
    awk -v m="${marker}" 'index($0, m) { exit } { print }' "${file}" | _strip_trailing_frame
}

# Print content between marker1 and marker2, with surrounding frames stripped
_extract_zone_between() {
    local file="$1"
    local m1="$2"
    local m2="$3"
    awk -v m1="${m1}" -v m2="${m2}" '
        index($0, m1) { inside = 1; next }
        index($0, m2) { exit }
        inside { print }
    ' "${file}" | _strip_leading_frame | _strip_trailing_frame
}

# Print content after the marker's box, with leading frame stripped
_extract_zone_below() {
    local file="$1"
    local marker="$2"
    awk -v m="${marker}" 'found { print } index($0, m) { found = 1 }' "${file}" | _strip_leading_frame
}

# Detect a local agent-contract format: "new" | "legacy" | "none"
_detect_format() {
    local file="$1"
    local has_template=false has_repo=false has_legacy=false
    grep -q "${TEMPLATE_BOUNDARY}" "${file}" 2>/dev/null && has_template=true
    grep -q "${REPO_BOUNDARY}" "${file}" 2>/dev/null && has_repo=true
    grep -q "${LEGACY_BOUNDARY}" "${file}" 2>/dev/null && has_legacy=true

    if [[ "${has_template}" == true && "${has_repo}" == true ]]; then
        echo "new"
    elif [[ "${has_legacy}" == true ]]; then
        echo "legacy"
    else
        echo "none"
    fi
}

# Emit a boundary block (3 lines: ━, marker, ━) to stdout
_emit_boundary_block() {
    local marker="$1"
    echo "${BOUNDARY_LINE}"
    echo "# ${marker}"
    echo "${BOUNDARY_LINE}"
}

migrate_legacy_agent_state() {
    header "Preserving Agent State"

    local state="${PROJECT_ROOT}/.claude/STATE.md"
    mkdir -p "${PROJECT_ROOT}/.claude/docs/research" \
        "${PROJECT_ROOT}/.claude/logs" "${PROJECT_ROOT}/.claude/checkpoints"
    if [[ ! -f "${state}" ]]; then
        cp -f "${TEMPLATE_DIR}/.claude/STATE.md" "${state}"
        UPDATED_FILES+=(".claude/STATE.md")
    fi
    if [[ ! -f "${PROJECT_ROOT}/.claude/docs/DESIGN.md" ]]; then
        cp -f "${TEMPLATE_DIR}/.claude/docs/DESIGN.md" \
            "${PROJECT_ROOT}/.claude/docs/DESIGN.md"
        UPDATED_FILES+=(".claude/docs/DESIGN.md")
    fi

    local source="" fmt="none" label=""
    for label in CLAUDE.md AGENTS.md; do
        local candidate="${PROJECT_ROOT}/${label}"
        [[ -f "${candidate}" && ! -L "${candidate}" ]] || continue
        fmt="$(_detect_format "${candidate}")"
        if [[ "${fmt}" != "none" ]]; then
            source="${candidate}"
            break
        fi
    done
    [[ -n "${source}" ]] || return 0

    local migration_marker="<!-- Migrated from legacy ${label} by scripts/update.sh. -->"
    if grep -Fqx "${migration_marker}" "${state}"; then
        info "Legacy state from ${label} was already migrated."
        return 0
    fi

    local identity="" working=""
    if [[ "${fmt}" == "new" ]]; then
        identity="$(_extract_zone_between "${source}" "${TEMPLATE_BOUNDARY}" "${REPO_BOUNDARY}")"
        working="$(_extract_zone_below "${source}" "${REPO_BOUNDARY}")"
    else
        working="$(_extract_zone_below "${source}" "${LEGACY_BOUNDARY}")"
    fi
    {
        echo ""
        echo "${migration_marker}"
        [[ -z "${identity}" ]] || printf '\n%s\n' "${identity}"
        [[ -z "${working}" ]] || printf '\n%s\n' "${working}"
    } >> "${state}"
    warn "Migrated legacy agent state from ${label} to .claude/STATE.md."
}

# Pre-2.0 installations shipped CLAUDE.md as a symlink to AGENTS.md. AGENTS.md
# is the only root contract now, so the link is simply removed: it carries no
# content of its own.
retire_claude_symlink() {
    header "Retiring Legacy CLAUDE.md Symlink"

    local link="${PROJECT_ROOT}/CLAUDE.md"
    if [[ ! -L "${link}" ]]; then
        info "No legacy CLAUDE.md symlink"
        return 0
    fi
    rm -f -- "${link}"
    UPDATED_FILES+=("REMOVED: CLAUDE.md (legacy symlink to AGENTS.md)")
}

# Claude Code reads the root AGENTS.md only when no CLAUDE.md, .claude/CLAUDE.md
# or CLAUDE.local.md is found in the working directory or above. Earlier template
# versions installed a CLAUDE.md, which would now load instead of AGENTS.md, so
# the file is moved aside — never deleted. migrate_legacy_agent_state has already
# copied any project-specific zones into .claude/STATE.md.
retire_root_claude_md() {
    header "Retiring Legacy CLAUDE.md"

    local existing="${PROJECT_ROOT}/CLAUDE.md"
    if [[ ! -f "${existing}" || -L "${existing}" ]]; then
        info "No root CLAUDE.md to retire"
        return 0
    fi

    local backup="${existing}.pre-agents-md.bak"
    if [[ -e "${backup}" || -L "${backup}" ]]; then
        backup="${backup}.$(date +%Y%m%d%H%M%S)-$$"
    fi
    mv -f "${existing}" "${backup}"
    UPDATED_FILES+=("MOVED: CLAUDE.md -> $(basename "${backup}")")
    warn "Moved CLAUDE.md to $(basename "${backup}")."
    warn "Claude Code loads CLAUDE.md instead of AGENTS.md when both exist, so leaving"
    warn "a CLAUDE.md in the repository silently disables the Orchestra contract."
    warn "Any project instructions it held are in .claude/STATE.md; delete the backup once reviewed."
}

# =============================================================================
# Phase 5: Native settings migration and diff
# =============================================================================
migrate_native_settings_paths() {
    local settings="${PROJECT_ROOT}/.claude/settings.json"
    [[ -f "${settings}" ]] || return 0
    if ! grep -Eq '\.agents/(hooks|logs)/' "${settings}"; then
        return 0
    fi

    sed -i -e 's#\.agents/hooks/#.claude/hooks/#g' \
        -e 's#\.agents/logs/#.claude/logs/#g' "${settings}"
    UPDATED_FILES+=(".claude/settings.json (migrated hook and log paths)")
    info "Migrated legacy .agents paths in settings to .claude paths."
}

check_settings_files() {
    header "Checking Settings Files"

    for file in "${SETTINGS_FILES[@]}"; do
        local src="${TEMPLATE_DIR}/${file}"
        local dst="${PROJECT_ROOT}/${file}"

        if [[ ! -f "${src}" ]]; then
            warn "Template does not contain ${file}, skipping."
            continue
        fi

        if [[ ! -f "${dst}" ]]; then
            info "Local ${file} does not exist. You may want to copy it from the template."
            info "  cp ${src} ${dst}"
            continue
        fi

        local settings_diff
        settings_diff="$(diff -u "${dst}" "${src}" --label "local" --label "template" 2>/dev/null || true)"

        if [[ -n "${settings_diff}" ]]; then
            warn "${file} differs from template (NOT auto-merged):"
            echo "${settings_diff}"
            echo ""
            warn "Please review and merge ${file} manually."
        else
            info "${file} matches template. No action needed."
        fi
    done
}

# A settings.json hook that names a script the update removed fails on every
# event it is registered for, so dangling references are reported here.
check_settings_references() {
    local settings="${PROJECT_ROOT}/.claude/settings.json"
    [[ -f "${settings}" ]] || return 0
    local reference missing=false
    while IFS= read -r reference; do
        [[ -n "${reference}" ]] || continue
        if [[ ! -e "${PROJECT_ROOT}/${reference}" ]]; then
            warn ".claude/settings.json references a missing file: ${reference}"
            missing=true
        fi
    done < <(grep -oE '\.claude/[A-Za-z0-9_./-]+\.(py|sh)' "${settings}" | sort -u || true)
    if [[ "${missing}" == true ]]; then
        warn "Remove those entries or merge the template's settings before starting Claude Code."
    fi
}

ensure_gitattributes_entries() {
    local gitattributes="${PROJECT_ROOT}/.gitattributes"
    local missing=() entry
    if [[ -L "${gitattributes}" || ( -e "${gitattributes}" && ! -f "${gitattributes}" ) ]]; then
        warn "Skipping .gitattributes: not a regular file."
        return 0
    fi
    touch "${gitattributes}"
    for entry in "${GITATTRIBUTES_ENTRIES[@]}"; do
        grep -Fqx -- "${entry}" "${gitattributes}" || missing+=("${entry}")
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0

    if [[ -s "${gitattributes}" ]]; then
        echo "" >> "${gitattributes}"
    fi
    echo "# Claude Code Orchestra: keep LF endings for shipped scripts and runtime files" >> "${gitattributes}"
    printf '%s\n' "${missing[@]}" >> "${gitattributes}"
    UPDATED_FILES+=(".gitattributes (LF entries for Orchestra paths)")
}

# =============================================================================
# Phase 6: Installed Orchestra version update
# =============================================================================
update_version() {
    header "Updating Orchestra Version"

    if [[ -f "${TEMPLATE_DIR}/VERSION" ]]; then
        local destination="${PROJECT_ROOT}/${LOCAL_VERSION_FILE}"
        mkdir -p "$(dirname "${destination}")"
        cp -f "${TEMPLATE_DIR}/VERSION" "${destination}.tmp.$$"
        mv -f "${destination}.tmp.$$" "${destination}"
        info "${LOCAL_VERSION_FILE} updated to ${BOLD}${NEW_VERSION}${RESET}"
        UPDATED_FILES+=("${LOCAL_VERSION_FILE}")
    else
        warn "No VERSION file in template. Skipping version update."
    fi
    record_template_source
}

# Installations that predate .claude/orchestra-source get one, so the next
# update keeps using this source. An existing record is never rewritten: it
# changes only when someone edits the committed file.
record_template_source() {
    local destination="${PROJECT_ROOT}/${SOURCE_FILE}"
    [[ -f "${destination}" ]] && return 0
    local source="${TEMPLATE_REPO}"
    if ! [[ "${source}" =~ ^(https?|ssh|git)://[^/]+/ || "${source}" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+: ]]; then
        source="${DEFAULT_TEMPLATE_REPO}"
    fi
    printf '%s\n' "${source}" > "${destination}"
    info "Recorded update source in ${SOURCE_FILE}: ${source}"
    UPDATED_FILES+=("${SOURCE_FILE}")
}

# =============================================================================
# Phase 7: Summary
# =============================================================================
print_summary() {
    header "Update Summary"

    echo ""
    info "Version: ${BOLD}${OLD_VERSION}${RESET} -> ${BOLD}${NEW_VERSION}${RESET}"
    echo ""

    if [[ ${#UPDATED_FILES[@]} -gt 0 ]]; then
        info "Updated files/directories:"
        for item in "${UPDATED_FILES[@]}"; do
            if [[ "${item}" == REMOVED:* ]]; then
                echo "  ${RED}-${RESET} ${item#REMOVED: }"
            else
                echo "  ${GREEN}+${RESET} ${item}"
            fi
        done
    else
        info "No files were updated."
    fi

    if [[ ${#KEPT_ENTRIES[@]} -gt 0 ]]; then
        echo ""
        info "Project-owned entries kept (not shipped by the template):"
        for item in "${KEPT_ENTRIES[@]}"; do
            echo "  = ${item}"
        done
        if [[ "${HAVE_MANIFEST}" == false ]]; then
            warn "Without a manifest these may include files an older template installed;"
            warn "delete any that are no longer wanted."
        fi
    fi
    if [[ -n "${BACKUP_ROOT}" ]]; then
        echo ""
        warn "${BACKED_UP_COUNT} replaced or removed path(s) were backed up to ${BACKUP_ROOT#"${PROJECT_ROOT}/"}/"
    fi

    echo ""

    # Check if settings file differed
    for file in "${SETTINGS_FILES[@]}"; do
        local src="${TEMPLATE_DIR}/${file}"
        local dst="${PROJECT_ROOT}/${file}"
        if [[ -f "${src}" && -f "${dst}" ]]; then
            local settings_diff
            settings_diff="$(diff -q "${dst}" "${src}" 2>/dev/null || true)"
            if [[ -n "${settings_diff}" ]]; then
                warn "Remember to review and manually merge: ${BOLD}${file}${RESET}"
            fi
        fi
    done

    echo ""

    if [[ "${SELF_UPDATED}" == "true" ]]; then
        warn "scripts/update.sh itself was updated during this run."
        warn "Run ${BOLD}./scripts/update.sh${RESET} once more to sync targets added in the new version (e.g. new template directories)."
        echo ""
    fi

    info "Please review the changes and commit when ready:"
    echo "  git add -A && git commit -m \"chore: update orchestra template to ${NEW_VERSION}\""
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "${BOLD}Claude Code Orchestra — Template Updater${RESET}"

    parse_args "$@"
    preflight_checks
    fetch_template
    migrate_legacy_native_data
    cleanup_deprecated_paths
    migrate_legacy_agent_state
    retire_claude_symlink
    retire_root_claude_md
    sync_safe_dirs
    sync_safe_files
    migrate_native_settings_paths
    check_settings_files
    check_settings_references
    ensure_gitattributes_entries
    update_version
    print_summary

    info "Done!"
}

main "$@"
