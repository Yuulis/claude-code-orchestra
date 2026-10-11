#!/usr/bin/env bash
# Install Claude Code Orchestra into an existing Git repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# Repository scripts/update.sh fetches from when neither ORCHESTRA_TEMPLATE_REPO
# nor .claude/orchestra-source names another one.
DEFAULT_TEMPLATE_REPO="https://github.com/Yuulis/claude-code-orchestra.git"
# Records where updates come from, so an install made from a fork keeps
# updating from that fork instead of silently switching to another repository.
SOURCE_FILE=".claude/orchestra-source"
# Lists the top-level entries of each template-owned directory that the
# template installed. scripts/update.sh removes an entry only when it is listed
# here and the new template no longer ships it; anything else is user-owned.
MANIFEST_FILE=".claude/orchestra-manifest"
# Template-owned directories are merged entry by entry (see merge_owned_dir):
# entries the template ships replace the project's copy, and entries it does not
# ship -- the project's own skills, agents, rules, hooks -- are kept.
TEMPLATE_OWNED_DIRS=(
    ".claude/rules"
    ".claude/skills"
    ".claude/agents"
    ".claude/hooks"
    ".agents/skills"
)
# Runtime content that pre-2.0 installations kept under .agents/. The main
# agent runtime is now physically owned by .claude/, so these paths are stale.
# They are reported as conflicts and only removed after the user accepts the
# backup, never migrated silently.
LEGACY_RUNTIME_PATHS=(
    ".agents/workflows"
    ".agents/rules"
    ".agents/agents"
    ".agents/hooks"
    ".agents/docs"
    ".agents/logs"
    ".agents/checkpoints"
    ".agents/STATE.md"
    ".codex/skills"
)
# Template-owned files that no template-owned directory already covers.
# `.claude/rules/`, `.claude/skills/`, `.claude/agents/`, `.claude/hooks/`,
# above are merged as directories, so their contents must not be repeated here.
TEMPLATE_OWNED_FILES=(
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
# Machine-readable native settings. These are the user's to edit — a downstream
# project changes its model, approval policy, or hooks here — so they are never
# overwritten; when they differ from the template a merge candidate is written
# beside them. Format: "<settings-path>:<candidate-path>".
NATIVE_SETTINGS=(
    ".claude/settings.json:.claude/settings.orchestra.json"
    ".codex/config.toml:.codex/config.orchestra.toml"
)
PROJECT_FILES_IF_MISSING=(
    ".claude/STATE.md"
    ".claude/docs/DESIGN.md"
    ".claude/docs/research/.gitkeep"
)
GITIGNORE_ENTRIES=(
    ".claude/settings.local.json"
    ".claude/settings.orchestra.json"
    ".codex/config.orchestra.toml"
    "CLAUDE.local.md"
    ".claude/logs/"
    ".claude/checkpoints/"
    ".orchestra-backup-*/"
)
# The shipped scripts must keep LF endings in every clone of the target
# repository: a teammate with core.autocrlf=true would otherwise check out
# "#!/usr/bin/env bash\r" and the updater could no longer run.
GITATTRIBUTES_ENTRIES=(
    "scripts/check.sh text eol=lf"
    "scripts/install.sh text eol=lf"
    "scripts/update.sh text eol=lf"
    ".claude/** text=auto eol=lf"
    ".agents/** text=auto eol=lf"
    ".codex/** text=auto eol=lf"
)
# First line of the root contract. An AGENTS.md that starts with it is a
# previous Orchestra install, not project instructions worth preserving.
CONTRACT_HEADER="# Claude Code Orchestra — Root Agent Contract"
MINIMUM_PYTHON="3.11"

AUTO_YES=false
FORCE=false
TARGET_ARG="."
TARGET_SET=false
TARGET_ROOT=""
BACKUP_ROOT=""
CONFLICTS=()
KEPT_ENTRIES=()
# Newline-separated entries of the previous manifest (no associative arrays:
# they would raise the bash floor above what the rest of the script needs).
PREVIOUS_MANIFEST=""

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; }

usage() {
    cat <<'EOF'
Usage: scripts/install.sh [OPTIONS] [TARGET_DIR]

Install Claude Code Orchestra into an existing Git repository.

Options:
  -y, --yes    Skip confirmation prompts
  -f, --force  Back up and replace conflicting template-owned paths
  -h, --help   Show this help message

Existing AGENTS.md and CLAUDE.md content is preserved in .claude/STATE.md.
The template installs the root AGENTS.md contract as a real file. An existing
CLAUDE.md is moved aside to CLAUDE.md.pre-agents-md.bak, because Claude Code
reads AGENTS.md only when no CLAUDE.md is present. Existing
.claude/settings.json and .codex/config.toml are never overwritten; merge
candidates are written to .claude/settings.orchestra.json and
.codex/config.orchestra.toml when the files differ.

With --force, template-owned directories (.claude/{rules,skills,agents,hooks},
.agents/skills) are backed up and merged entry by entry: template entries are
installed, the project's own entries are kept.

The source repository is recorded in .claude/orchestra-source for
scripts/update.sh. It is ORCHESTRA_TEMPLATE_REPO when set, else the template
clone's remote "origin", else:
  https://github.com/Yuulis/claude-code-orchestra.git
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                usage >&2
                exit 2
                ;;
            *)
                if [[ "${TARGET_SET}" == true ]]; then
                    error "Only one TARGET_DIR may be specified."
                    exit 2
                fi
                TARGET_ARG="$1"
                TARGET_SET=true
                shift
                ;;
        esac
    done
}

require_source_paths() {
    local path
    for path in "${TEMPLATE_OWNED_DIRS[@]}" \
        "${TEMPLATE_OWNED_FILES[@]}" "${PROJECT_FILES_IF_MISSING[@]}" \
        "AGENTS.md" ".claude/settings.json" ".codex/config.toml" \
        "VERSION"; do
        if [[ ! -e "${SOURCE_ROOT}/${path}" && ! -L "${SOURCE_ROOT}/${path}" ]]; then
            error "Template source is incomplete: ${path} is missing."
            exit 1
        fi
    done
}

resolve_target() {
    if [[ ! -d "${TARGET_ARG}" ]]; then
        error "Target directory does not exist: ${TARGET_ARG}"
        exit 2
    fi
    TARGET_ROOT="$(cd "${TARGET_ARG}" && pwd -P)"
    if [[ "${TARGET_ROOT}" == "${SOURCE_ROOT}" ]]; then
        error "The template repository cannot be installed into itself."
        error "Use scripts/update.sh to update an existing installation."
        exit 2
    fi
    if ! git -C "${TARGET_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
        error "Target is not a Git repository: ${TARGET_ROOT}"
        exit 2
    fi
}

validate_destination_paths() {
    local path resolved parent component current
    local paths=(
        "${TEMPLATE_OWNED_DIRS[@]}"
        "${LEGACY_RUNTIME_PATHS[@]}"
        "${TEMPLATE_OWNED_FILES[@]}"
        "${PROJECT_FILES_IF_MISSING[@]}"
        "AGENTS.md"
        "CLAUDE.md"
        "CLAUDE.md.pre-agents-md.bak"
        ".claude/settings.json"
        ".claude/settings.orchestra.json"
        ".claude/orchestra-version"
        "${SOURCE_FILE}"
        "${MANIFEST_FILE}"
        ".codex/config.toml"
        ".codex/config.orchestra.toml"
        ".gitignore"
        ".gitattributes"
    )
    for path in "${paths[@]}"; do
        current="${TARGET_ROOT}"
        parent="$(dirname "${path}")"
        IFS='/' read -r -a parent_components <<< "${parent}"
        for component in "${parent_components[@]}"; do
            [[ "${component}" == "." || -z "${component}" ]] && continue
            current="${current}/${component}"
            if [[ -L "${current}" ]]; then
                error "Refusing symlinked parent for managed path: ${path}"
                exit 2
            fi
        done

        resolved="$(realpath -m -- "${TARGET_ROOT}/${path}")"
        if [[ "${resolved}" != "${TARGET_ROOT}/"* ]]; then
            error "Refusing path that resolves outside the target: ${path} -> ${resolved}"
            exit 2
        fi
    done
}

validate_project_files() {
    local path destination
    local project_files=(
        "AGENTS.md"
        "CLAUDE.md"
        ".claude/settings.json"
        ".codex/config.toml"
        ".claude/STATE.md"
        ".claude/docs/DESIGN.md"
        ".gitignore"
        ".gitattributes"
    )
    for path in "${project_files[@]}"; do
        destination="${TARGET_ROOT}/${path}"
        if [[ -L "${destination}" ]]; then
            # A pre-2.0 CLAUDE.md -> AGENTS.md link is the one symlink we know
            # how to retire: it is backed up as a conflict and then removed, so
            # AGENTS.md is the only root contract. Any other symlink here is
            # still refused.
            if [[ "${path}" != "CLAUDE.md" ]]; then
                error "Refusing project-owned symlink: ${path}"
                exit 2
            fi
            continue
        fi
        if [[ -e "${destination}" && ! -f "${destination}" ]]; then
            error "Expected a regular file at project-owned path: ${path}"
            exit 2
        fi
        if [[ -f "${destination}" && ! -r "${destination}" ]]; then
            error "Project-owned file is not readable: ${path}"
            exit 2
        fi
    done
}

collect_conflicts() {
    local path
    for path in "${TEMPLATE_OWNED_DIRS[@]}" "${LEGACY_RUNTIME_PATHS[@]}" \
        "${TEMPLATE_OWNED_FILES[@]}"; do
        if [[ -e "${TARGET_ROOT}/${path}" || -L "${TARGET_ROOT}/${path}" ]]; then
            CONFLICTS+=("${path}")
        fi
    done

    # A pre-2.0 installation left CLAUDE.md as a symlink to AGENTS.md. AGENTS.md
    # is a real file now, so report the link instead of writing through it.
    if [[ -L "${TARGET_ROOT}/CLAUDE.md" ]]; then
        CONFLICTS+=("CLAUDE.md")
    fi

    if [[ ${#CONFLICTS[@]} -eq 0 ]]; then
        return 0
    fi

    warn "Template-owned paths already exist:"
    printf '  %s\n' "${CONFLICTS[@]}"
    if [[ "${FORCE}" == false ]]; then
        error "Installation stopped before making changes."
        error "Review the paths, then re-run with --force. They are backed up first;"
        error "template entries are then installed and the project's own entries kept."
        exit 2
    fi
}

confirm_install() {
    local status
    status="$(git -C "${TARGET_ROOT}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${status}" ]]; then
        warn "The target repository has uncommitted or untracked changes."
    fi
    if [[ "${AUTO_YES}" == true ]]; then
        return 0
    fi

    local response
    read -r -p "Install Orchestra into ${TARGET_ROOT}? [y/N] " response
    case "${response}" in
        [yY]|[yY][eE][sS]) ;;
        *)
            info "Installation cancelled."
            exit 0
            ;;
    esac
}

backup_conflicts() {
    [[ ${#CONFLICTS[@]} -gt 0 ]] || return 0

    BACKUP_ROOT="${TARGET_ROOT}/.orchestra-backup-$(date +%Y%m%d%H%M%S)-$$"
    local path
    for path in "${CONFLICTS[@]}"; do
        mkdir -p "${BACKUP_ROOT}/$(dirname "${path}")"
        cp -a "${TARGET_ROOT}/${path}" "${BACKUP_ROOT}/${path}"
    done
    warn "Conflicting paths were backed up to ${BACKUP_ROOT}"
}

# Reads the manifest the previous install or update wrote, so entries the
# template has since dropped can be told apart from the project's own entries.
load_previous_manifest() {
    local manifest="${TARGET_ROOT}/${MANIFEST_FILE}"
    [[ -f "${manifest}" ]] || return 0
    PREVIOUS_MANIFEST="$(grep -v '^#' "${manifest}" || true)"
}

# Succeeds when the newline-separated list in $1 contains the line $2.
list_contains() {
    [[ -n "$1" ]] && grep -Fqx -- "$2" <<< "$1"
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

# Merges one template-owned directory entry by entry. The whole directory was
# already backed up by backup_conflicts when it existed, so nothing removed or
# replaced here is lost.
merge_owned_dir() {
    local dir="$1"
    local source_dir="${SOURCE_ROOT}/${dir}"
    local destination="${TARGET_ROOT}/${dir}"
    local name shipped existing

    if [[ -L "${destination}" || ( -e "${destination}" && ! -d "${destination}" ) ]]; then
        rm -rf -- "${destination}"
    fi
    mkdir -p "${destination}"

    shipped="$(list_entries "${source_dir}")" || exit 1
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        rm -rf -- "${destination:?}/${name}"
        cp -a "${source_dir}/${name}" "${destination}/${name}"
    done <<< "${shipped}"

    existing="$(list_entries "${destination}")" || exit 1
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        list_contains "${shipped}" "${name}" && continue
        if list_contains "${PREVIOUS_MANIFEST}" "${dir}/${name}"; then
            rm -rf -- "${destination:?}/${name}"
            info "Removed ${dir}/${name} (no longer shipped by the template)"
        elif is_stale_codex_skill_copy "${dir}" "${destination}/${name}" "${name}"; then
            rm -rf -- "${destination:?}/${name}"
            info "Removed ${dir}/${name} (stale copy; replaced by links)"
        else
            KEPT_ENTRIES+=("${dir}/${name}")
        fi
    done <<< "${existing}"
    info "Installed ${dir}/"
}

# Pre-2.0 installs kept real copies of the template skills in .agents/skills/.
# Today every template entry there is a link into .claude/skills/, so a real
# directory named after a template skill is a stale copy, not project content.
is_stale_codex_skill_copy() {
    local dir="$1" path="$2" name="$3"
    [[ "${dir}" == ".agents/skills" && -d "${path}" && ! -L "${path}" ]] || return 1
    [[ -e "${SOURCE_ROOT}/.claude/skills/${name}" ]]
}

copy_owned_paths() {
    local path destination temporary
    load_previous_manifest
    for path in "${TEMPLATE_OWNED_DIRS[@]}"; do
        merge_owned_dir "${path}"
    done

    for path in "${TEMPLATE_OWNED_FILES[@]}"; do
        destination="${TARGET_ROOT}/${path}"
        mkdir -p "$(dirname "${destination}")"
        temporary="${destination}.tmp.$$"
        cp -a "${SOURCE_ROOT}/${path}" "${temporary}"
        mv -f "${temporary}" "${destination}"
        info "Installed ${path}"
    done
    chmod +x "${TARGET_ROOT}/scripts/check.sh" \
        "${TARGET_ROOT}/scripts/install.sh" "${TARGET_ROOT}/scripts/update.sh"
}

write_manifest() {
    local destination="${TARGET_ROOT}/${MANIFEST_FILE}"
    local dir name entries=""
    for dir in "${TEMPLATE_OWNED_DIRS[@]}"; do
        entries+="$(list_entries "${SOURCE_ROOT}/${dir}" | sed "s#^#${dir}/#")" || exit 1
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
}

remove_legacy_runtime_paths() {
    local path
    for path in "${LEGACY_RUNTIME_PATHS[@]}" "CLAUDE.md"; do
        if [[ "${path}" == "CLAUDE.md" && ! -L "${TARGET_ROOT}/CLAUDE.md" ]]; then
            continue
        fi
        if [[ -e "${TARGET_ROOT}/${path}" || -L "${TARGET_ROOT}/${path}" ]]; then
            rm -rf -- "${TARGET_ROOT:?}/${path}"
            info "Removed legacy path ${path}"
        fi
    done
}

copy_project_files_if_missing() {
    local path destination
    for path in "${PROJECT_FILES_IF_MISSING[@]}"; do
        destination="${TARGET_ROOT}/${path}"
        if [[ -e "${destination}" || -L "${destination}" ]]; then
            info "Preserved existing ${path}"
            continue
        fi
        mkdir -p "$(dirname "${destination}")"
        cp -a "${SOURCE_ROOT}/${path}" "${destination}"
        info "Installed ${path}"
    done
}

install_agent_files() {
    local existing_agents="${TARGET_ROOT}/AGENTS.md"
    local existing_claude="${TARGET_ROOT}/CLAUDE.md"
    local state="${TARGET_ROOT}/.claude/STATE.md"
    local name source destination temporary
    mkdir -p "${TARGET_ROOT}/.claude/logs" "${TARGET_ROOT}/.claude/checkpoints"

    if [[ -f "${existing_agents}" ]] && is_orchestra_contract "${existing_agents}"; then
        # A re-run (install --force) finds the contract it installed last time.
        # Appending it would copy ~400 lines of template into project state.
        info "Existing AGENTS.md is an Orchestra contract; not copied into .claude/STATE.md"
        if ! cmp -s "${existing_agents}" "${SOURCE_ROOT}/AGENTS.md"; then
            # Edited or older contract: it is replaced below, so keep a copy.
            [[ -n "${BACKUP_ROOT}" ]] ||
                BACKUP_ROOT="${TARGET_ROOT}/.orchestra-backup-$(date +%Y%m%d%H%M%S)-$$"
            mkdir -p "${BACKUP_ROOT}"
            cp -a "${existing_agents}" "${BACKUP_ROOT}/AGENTS.md"
            warn "Existing AGENTS.md differs from the template; backed up to ${BACKUP_ROOT#"${TARGET_ROOT}/"}/AGENTS.md"
        fi
    elif [[ -f "${existing_agents}" ]]; then
        {
            echo ""
            echo "<!-- Existing AGENTS.md content preserved by scripts/install.sh. -->"
            echo ""
            cat "${existing_agents}"
        } >> "${state}"
    fi
    if [[ -f "${existing_claude}" ]] \
        && { [[ ! -f "${existing_agents}" ]] || ! cmp -s "${existing_agents}" "${existing_claude}"; }; then
        {
            echo ""
            echo "<!-- Existing CLAUDE.md content preserved by scripts/install.sh. -->"
            echo ""
            cat "${existing_claude}"
        } >> "${state}"
    fi
    name="AGENTS.md"
    source="${SOURCE_ROOT}/${name}"
    destination="${TARGET_ROOT}/${name}"
    temporary="${TARGET_ROOT}/.${name}.tmp.$$"
    cp -a "${source}" "${temporary}"
    mv -f "${temporary}" "${destination}"
    info "Installed AGENTS.md; preserved existing instructions in .claude/STATE.md"
    retire_target_claude_md
}

is_orchestra_contract() {
    local file="$1" first_line=""
    cmp -s "${file}" "${SOURCE_ROOT}/AGENTS.md" && return 0
    IFS= read -r first_line < "${file}" || true
    [[ "${first_line}" == "${CONTRACT_HEADER}" ]]
}

# Claude Code reads the root AGENTS.md only when no CLAUDE.md, .claude/CLAUDE.md
# or CLAUDE.local.md is found in the working directory or above. A CLAUDE.md
# left in place would therefore load instead of the Orchestra contract, so the
# file is moved aside — never deleted; its content is already in .claude/STATE.md.
retire_target_claude_md() {
    local existing="${TARGET_ROOT}/CLAUDE.md"
    [[ -f "${existing}" && ! -L "${existing}" ]] || return 0

    local backup="${existing}.pre-agents-md.bak"
    if [[ -e "${backup}" || -L "${backup}" ]]; then
        backup="${backup}.$(date +%Y%m%d%H%M%S)-$$"
    fi
    mv -f "${existing}" "${backup}"
    warn "Moved CLAUDE.md to $(basename "${backup}")."
    warn "Claude Code loads CLAUDE.md instead of AGENTS.md when both exist, so leaving"
    warn "a CLAUDE.md in the repository silently disables the Orchestra contract."
    warn "Its instructions were preserved in .claude/STATE.md; delete the backup once reviewed."
}

install_settings() {
    local entry settings_path candidate_path source destination candidate
    for entry in "${NATIVE_SETTINGS[@]}"; do
        settings_path="${entry%%:*}"
        candidate_path="${entry##*:}"
        source="${SOURCE_ROOT}/${settings_path}"
        destination="${TARGET_ROOT}/${settings_path}"
        candidate="${TARGET_ROOT}/${candidate_path}"
        mkdir -p "$(dirname "${destination}")"

        if [[ ! -f "${destination}" ]]; then
            cp -a "${source}" "${destination}"
            info "Installed ${settings_path}"
            continue
        fi
        if cmp -s "${source}" "${destination}"; then
            info "Preserved matching ${settings_path}"
            continue
        fi

        cp -a "${source}" "${candidate}.tmp.$$"
        mv -f "${candidate}.tmp.$$" "${candidate}"
        warn "Preserved existing ${settings_path}."
        warn "Merge required Orchestra settings from ${candidate_path}, then delete the candidate."
    done
}

install_version_marker() {
    local destination="${TARGET_ROOT}/.claude/orchestra-version"
    cp -a "${SOURCE_ROOT}/VERSION" "${destination}.tmp.$$"
    mv -f "${destination}.tmp.$$" "${destination}"
    info "Recorded Orchestra version in .claude/orchestra-version"
    write_manifest
    info "Recorded template-owned entries in ${MANIFEST_FILE}"
}

# A local path (the temporary clone the README uses) would be gone by the time
# scripts/update.sh runs, so only a remote URL is worth recording.
is_remote_url() {
    local url="$1"
    [[ -n "${url}" && "${url}" != -* ]] || return 1
    [[ "${url}" =~ ^(https?|ssh|git)://[^/]+/ || "${url}" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+: ]]
}

record_template_source() {
    local destination="${TARGET_ROOT}/${SOURCE_FILE}"
    local source="${ORCHESTRA_TEMPLATE_REPO:-}"
    if [[ -z "${source}" ]]; then
        source="$(git -C "${SOURCE_ROOT}" remote get-url origin 2>/dev/null || true)"
    fi
    if ! is_remote_url "${source}"; then
        source="${DEFAULT_TEMPLATE_REPO}"
    fi
    printf '%s\n' "${source}" > "${destination}.tmp.$$"
    mv -f "${destination}.tmp.$$" "${destination}"
    info "Recorded update source in ${SOURCE_FILE}: ${source}"
}

ensure_gitignore_entries() {
    local gitignore="${TARGET_ROOT}/.gitignore"
    local missing=()
    local entry
    touch "${gitignore}"
    for entry in "${GITIGNORE_ENTRIES[@]}"; do
        if ! grep -Fqx "${entry}" "${gitignore}"; then
            missing+=("${entry}")
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0

    if [[ -s "${gitignore}" ]]; then
        echo "" >> "${gitignore}"
    fi
    echo "# Claude Code Orchestra local state" >> "${gitignore}"
    printf '%s\n' "${missing[@]}" >> "${gitignore}"
    info "Updated .gitignore with Orchestra local-state paths"
}

ensure_gitattributes_entries() {
    local gitattributes="${TARGET_ROOT}/.gitattributes"
    local missing=()
    local entry
    touch "${gitattributes}"
    for entry in "${GITATTRIBUTES_ENTRIES[@]}"; do
        if ! grep -Fqx "${entry}" "${gitattributes}"; then
            missing+=("${entry}")
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0

    if [[ -s "${gitattributes}" ]]; then
        echo "" >> "${gitattributes}"
    fi
    echo "# Claude Code Orchestra: keep LF endings for shipped scripts and runtime files" >> "${gitattributes}"
    printf '%s\n' "${missing[@]}" >> "${gitattributes}"
    info "Updated .gitattributes so Orchestra scripts keep LF line endings"
}

# The bundled hooks and skill scripts use datetime.UTC and tomllib. Warn rather
# than fail: the files install fine, only running them needs the newer Python.
check_python_version() {
    if ! command -v python3 &>/dev/null; then
        warn "python3 was not found; Orchestra hooks and skill scripts need Python ${MINIMUM_PYTHON}+."
        return 0
    fi
    if ! python3 -c "import sys; sys.exit(sys.version_info < tuple(map(int, '${MINIMUM_PYTHON}'.split('.'))))" 2>/dev/null; then
        warn "python3 is $(python3 -c 'import platform; print(platform.python_version())' 2>/dev/null || echo unknown);"
        warn "Orchestra hooks and skill scripts need Python ${MINIMUM_PYTHON}+."
    fi
}

print_summary() {
    echo ""
    info "Claude Code Orchestra installation complete."
    if [[ ${#KEPT_ENTRIES[@]} -gt 0 ]]; then
        info "Project-owned entries kept in template directories (not shipped by the template):"
        printf '  %s\n' "${KEPT_ENTRIES[@]}"
    fi
    if [[ -n "${BACKUP_ROOT}" ]]; then
        info "Everything replaced or removed is in ${BACKUP_ROOT#"${TARGET_ROOT}/"}/"
    fi
    info "Project files such as README.md and VERSION were preserved."
    if [[ -f "${TARGET_ROOT}/.claude/settings.orchestra.json" ]]; then
        warn "Complete the settings merge before starting Claude Code."
    else
        info "Next: start Claude Code and run /init."
    fi
}

main() {
    parse_args "$@"
    require_source_paths
    resolve_target
    validate_destination_paths
    validate_project_files
    collect_conflicts
    confirm_install
    backup_conflicts
    remove_legacy_runtime_paths
    copy_owned_paths
    copy_project_files_if_missing
    install_agent_files
    install_settings
    install_version_marker
    record_template_source
    ensure_gitignore_entries
    ensure_gitattributes_entries
    check_python_version
    print_summary
}

main "$@"
