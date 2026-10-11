#!/usr/bin/env bash
# scripts/check.sh -- Consistency checker for the repository's agent contracts.
# Validates shared contracts, bootstraps, tier IDs, model coherence, and updater config.
# Exit 0 only if all checks pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
# Written by scripts/install.sh and scripts/update.sh in an installed project.
# It lists the template-owned entries; anything else under .claude/agents/ or
# .claude/skills/ is the project's own and is not held to the template catalog.
MANIFEST="${ROOT}/.claude/orchestra-manifest"

# Succeeds for template content: everything in the template repository itself
# (no manifest), and only manifest-listed entries in an installed project.
is_template_entry() {
    [[ -f "${MANIFEST}" ]] || return 0
    grep -Fqx -- "$1" "${MANIFEST}"
}

check() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name}"
        FAIL=$((FAIL + 1))
    fi
}

# --------------------------------------------------------------------------
# 1) Every relative markdown link / canonical-file path in INDEX.md exists
# --------------------------------------------------------------------------
check_index_links() {
    local index="${ROOT}/.claude/docs/INDEX.md"
    if [[ ! -f "${index}" ]]; then
        echo "  INDEX.md not found"
        return 1
    fi
    local ok=true
    # Extract paths that look like relative refs: backtick-wrapped or link targets
    # Matches: `path/to/file` and (path/to/file) patterns
    local paths
    paths=$(grep -oE '`\.[^`]+`' "${index}" | tr -d '`' || true)
    paths+=$'\n'
    paths+=$(grep -oE '\(\.[^)]+\)' "${index}" | tr -d '()' || true)
    # Deduplicate and filter
    paths=$(echo "${paths}" | sort -u | grep -v '^$' || true)
    while IFS= read -r p; do
        [[ -z "${p}" ]] && continue
        local target="${ROOT}/${p}"
        if [[ ! -e "${target}" ]]; then
            echo "  Missing: ${p}"
            ok=false
        fi
    done <<< "${paths}"
    ${ok}
}
check "INDEX.md links resolve" check_index_links

# --------------------------------------------------------------------------
# 2) Tier IDs default/sol/fable all appear in tiers.md
# --------------------------------------------------------------------------
check_tier_ids() {
    local tiers="${ROOT}/.claude/rules/tiers.md"
    if [[ ! -f "${tiers}" ]]; then
        echo "  tiers.md not found"
        return 1
    fi
    local ok=true
    for id in default sol fable; do
        if ! grep -q "\`${id}\`" "${tiers}"; then
            echo "  Missing tier ID: ${id}"
            ok=false
        fi
    done
    ${ok}
}
check "Tier IDs present in tiers.md" check_tier_ids

# --------------------------------------------------------------------------
# 3) Model coherence: CODEX_MODEL in settings.json == model in config.toml
#    == fallback values in ${CODEX_MODEL:-...} across .claude/ and .codex/
# --------------------------------------------------------------------------
check_model_coherence() {
    local settings="${ROOT}/.claude/settings.json"
    local config="${ROOT}/.codex/config.toml"
    local ok=true

    # Extract CODEX_MODEL from settings.json
    local settings_model
    settings_model=$(python3 -c "
import json, sys
with open('${settings}') as f:
    d = json.load(f)
print(d.get('env', {}).get('CODEX_MODEL', ''))
" 2>/dev/null)

    if [[ -z "${settings_model}" ]]; then
        echo "  Could not read CODEX_MODEL from ${settings}"
        return 1
    fi

    # Extract model from config.toml (simple grep; avoids toml parser dep)
    local config_model
    config_model=$(grep -E '^model\s*=' "${config}" | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')

    if [[ -z "${config_model}" ]]; then
        echo "  Could not read model from ${config}"
        return 1
    fi

    # Compare settings vs config
    if [[ "${settings_model}" != "${config_model}" ]]; then
        echo "  Mismatch: settings.json CODEX_MODEL=${settings_model} vs config.toml model=${config_model}"
        ok=false
    fi

    # Extract distinct fallback values from ${CODEX_MODEL:-...} patterns
    local fallbacks
    fallbacks=$(grep -rhoE --exclude-dir=logs '\$\{CODEX_MODEL:-[^}]+\}' "${ROOT}/.claude/" "${ROOT}/.codex/" 2>/dev/null \
        | sed 's/.*:-\(.*\)}/\1/' \
        | sort -u || true)

    while IFS= read -r fb; do
        [[ -z "${fb}" ]] && continue
        if [[ "${fb}" != "${settings_model}" ]]; then
            echo "  Mismatch: fallback ${fb} != CODEX_MODEL ${settings_model}"
            ok=false
        fi
    done <<< "${fallbacks}"

    # The shared Codex wrapper carries the same fallback in Python, so it has
    # to move with the single centralized model value too.
    local consult="${ROOT}/.claude/skills/_shared/codex_consult.py"
    if [[ -f "${consult}" ]]; then
        local consult_model
        consult_model=$(grep -E '^DEFAULT_MODEL\s*=' "${consult}" \
            | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')
        if [[ -z "${consult_model}" ]]; then
            echo "  Could not read DEFAULT_MODEL from codex_consult.py"
            ok=false
        elif [[ "${consult_model}" != "${settings_model}" ]]; then
            echo "  Mismatch: codex_consult.py DEFAULT_MODEL=${consult_model} != CODEX_MODEL ${settings_model}"
            ok=false
        fi
    fi

    ${ok}
}
check "Model coherence" check_model_coherence

# --------------------------------------------------------------------------
# 4) Template-owned runtime subdirectories are listed in SAFE_DIRS
# --------------------------------------------------------------------------
check_safe_dirs() {
    local update="${ROOT}/scripts/update.sh"
    if [[ ! -f "${update}" ]]; then
        echo "  scripts/update.sh not found"
        return 1
    fi
    local dir
    for dir in .claude/rules .claude/skills .claude/agents .claude/hooks .agents/skills; do
        if ! grep -q "\"${dir}\"" "${update}"; then
            echo "  ${dir} not found in SAFE_DIRS"
            return 1
        fi
    done
}
check "Template runtime paths in SAFE_DIRS" check_safe_dirs

# --------------------------------------------------------------------------
# 5) Root AGENTS.md is the complete contract: the main-agent orchestration
#    policy and the CLI-executor contract now live in the one file every
#    runtime auto-loads.
# --------------------------------------------------------------------------
check_root_contract() {
    local contract="${ROOT}/AGENTS.md"
    if [[ ! -f "${contract}" || -L "${contract}" ]]; then
        echo "  AGENTS.md not found, or is a symlink instead of a real file"
        return 1
    fi

    local ok=true
    # Both halves of the merged contract. The main-agent policy sections come
    # first, the CLI-executor sections after; a delegated run loads this file
    # and nothing else, so every section has to be in it.
    local headings=(
        "## Mission"
        "## Non-Goals"
        "## Agent Topology"
        "## Routing Policy"
        "## Skill Catalog"
        "## Execution Patterns"
        "## Context and Document Ownership"
        "## Quality Gates"
        "## Language Protocol"
        "## Native Runtime Boundary"
        "## Required Response Structure"
        "## Handoff Rules"
        "## Cross-CLI Subagent Invocation"
        "## Internal Context References"
        "## Guardrails (Completion Verification)"
    )
    local heading
    for heading in "${headings[@]}"; do
        if ! grep -Fxq "${heading}" "${contract}"; then
            echo "  Missing contract heading: ${heading}"
            ok=false
        fi
    done

    local definition
    for definition in "${ROOT}"/.claude/agents/*.md; do
        local agent_name
        agent_name="$(basename "${definition}" .md)"
        is_template_entry ".claude/agents/${agent_name}.md" || continue
        grep -Fq "\`${agent_name}\`" "${contract}" || {
            echo "  Missing agent in AGENTS.md catalog: ${agent_name}"
            ok=false
        }
    done
    for definition in "${ROOT}"/.claude/skills/*/SKILL.md; do
        local skill_name
        skill_name="$(basename "$(dirname "${definition}")")"
        is_template_entry ".claude/skills/${skill_name}" || continue
        grep -Fq "\`${skill_name}\`" "${contract}" || {
            echo "  Missing skill in AGENTS.md catalog: ${skill_name}"
            ok=false
        }
    done

    # Runtime adapters stay reachable from the one contract every CLI loads.
    local reference
    for reference in ".agents/AGENTS.md" ".codex/AGENTS.md" \
        ".claude/rules/tiers.md"; do
        grep -Fq "${reference}" "${contract}" || {
            echo "  Missing route in root AGENTS.md: ${reference}"
            ok=false
        }
    done

    if [[ -e "${ROOT}/.claude/rules/orchestration.md" ]]; then
        echo "  Duplicate orchestration contract still exists under .claude/rules/"
        ok=false
    fi

    local index_entry
    index_entry=$(grep -F 'Root agent contract' "${ROOT}/.claude/docs/INDEX.md" || true)
    if [[ "${index_entry}" != *"normative"* ]]; then
        echo "  Root agent contract is not registered as normative in INDEX.md"
        ok=false
    fi

    ${ok}
}
check "Root orchestration contract" check_root_contract

# --------------------------------------------------------------------------
# 5b) No CLAUDE.md anywhere: Claude Code reads root AGENTS.md directly ONLY
#     while no CLAUDE.md sits in the working directory or above it. A
#     CLAUDE.md shadows the contract silently -- no warning, no error.
# --------------------------------------------------------------------------
check_no_claude_md() {
    local ok=true
    local shadow
    for shadow in CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md; do
        if [[ -e "${ROOT}/${shadow}" || -L "${ROOT}/${shadow}" ]]; then
            echo "  ${shadow} exists: Claude Code reads it instead of root AGENTS.md"
            echo "  and silently stops loading the contract. Delete it; the merged"
            echo "  main-agent policy belongs in AGENTS.md."
            ok=false
        fi
    done
    ${ok}
}
check "No CLAUDE.md shadows AGENTS.md" check_no_claude_md

# --------------------------------------------------------------------------
# 6) Root instructions stay bounded and carry the always-needed information
# --------------------------------------------------------------------------
check_ordered_references() {
    local file="$1"
    shift
    local previous_line=0
    local reference
    local current_line

    for reference in "$@"; do
        current_line=$(grep -nF -- "${reference}" "${file}" | head -1 | cut -d: -f1 || true)
        if [[ -z "${current_line}" ]]; then
            echo "  Missing reference in ${file#"${ROOT}/"}: ${reference}"
            return 1
        fi
        if ((current_line <= previous_line)); then
            echo "  Out-of-order reference in ${file#"${ROOT}/"}: ${reference}"
            return 1
        fi
        previous_line=${current_line}
    done
}

check_bootstrap_references() {
    local root_agents="${ROOT}/AGENTS.md"
    local ok=true

    # The merged contract carries two roles, so the cap is 400 rather than the
    # 150 that bounded the old router-only file. It is a ceiling, not a target:
    # detail belongs under .claude/rules/.
    if (( $(wc -l < "${root_agents}") > 400 )); then
        echo "  AGENTS.md exceeds 400 lines"
        ok=false
    fi
    local reference
    for reference in ".claude/rules/" ".claude/skills/" ".claude/agents/" \
        ".claude/STATE.md" ".claude/docs/DESIGN.md" ".claude/docs/change_main.md"; do
        grep -Fq "${reference}" "${root_agents}" || {
            echo "  Missing essential root instruction: ${reference}"
            ok=false
        }
    done
    grep -Fq "Japanese" "${root_agents}" || ok=false
    grep -Fqi "verify" "${root_agents}" || ok=false
    if grep -q '@orchestra:' "${root_agents}"; then
        echo "  Legacy boundary marker found in AGENTS.md"
        ok=false
    fi

    ${ok}
}
check "Bootstrap references" check_bootstrap_references

# --------------------------------------------------------------------------
# 7) Runtime layout: .claude/ is the physical source, .agents/ and .codex/
#    carry subagent schema only
# --------------------------------------------------------------------------
check_native_boundaries() {
    local ok=true
    local canonical_dir
    for canonical_dir in rules skills agents hooks docs logs checkpoints; do
        local canonical="${ROOT}/.claude/${canonical_dir}"
        if [[ ! -d "${canonical}" || -L "${canonical}" ]]; then
            echo "  Canonical runtime directory is missing or a symlink: .claude/${canonical_dir}"
            ok=false
        fi
    done

    # Every contract file is a real file so the checkout survives filesystems
    # and CI runners that do not honour symlinks. The only links in the layout
    # are the .agents/skills/ entries validated below, and losing them costs
    # Codex its skill list, never a contract.
    local real_file
    for real_file in AGENTS.md .agents/AGENTS.md .codex/AGENTS.md \
        .claude/STATE.md .claude/rules/tiers.md .claude/docs/INDEX.md \
        .claude/docs/change_main.md; do
        if [[ ! -f "${ROOT}/${real_file}" || -L "${ROOT}/${real_file}" ]]; then
            echo "  Must be a real file, not a symlink or missing: ${real_file}"
            ok=false
        fi
    done

    # Known leftovers of earlier template layouts. Only these are rejected:
    # .claude/, .agents/ and .codex/ are shared with the project and the CLIs
    # themselves (.claude/commands/, .claude/output-styles/, .codex/prompts/,
    # ...), so an entry the template does not know is the project's business.
    # Shared runtime content must not be duplicated back into the subagent
    # schema directories, and template files that skills replaced must go.
    local legacy_path
    for legacy_path in \
        .agents/rules .agents/agents .agents/hooks .agents/workflows \
        .agents/docs .agents/logs .agents/checkpoints .agents/STATE.md \
        .agents/INDEX.md .agents/tiers.md .agents/change_main.md .agents/check.sh \
        .codex/skills .codex/commands \
        .codex/prompts/analyze.md .codex/prompts/consult.md \
        .codex/prompts/review-architecture.md .codex/prompts/update-design.md \
        .claude/commands/research-lib.md .claude/commands/simplify.md \
        .claude/commands/update-lib-docs.md; do
        if [[ -e "${ROOT}/${legacy_path}" || -L "${ROOT}/${legacy_path}" ]]; then
            echo "  Legacy template path from an earlier layout: ${legacy_path}"
            ok=false
        fi
    done

    # .agents/skills/ is where Codex discovers project skills. Every template
    # entry there is a relative link to the canonical .claude/skills/ copy --
    # never a copy, and never a Claude-lead workflow that calls the Task tool,
    # which Codex cannot run. A project may add its own Codex skills: a real
    # directory is fine unless it shadows a canonical skill of the same name.
    local skills_dir="${ROOT}/.agents/skills"
    if [[ ! -d "${skills_dir}" || -L "${skills_dir}" ]]; then
        echo "  .agents/skills must be a real directory of skill links"
        ok=false
    else
        local skill_link skill_name
        for skill_link in "${skills_dir}"/* "${skills_dir}"/.[!.]*; do
            [[ -e "${skill_link}" || -L "${skill_link}" ]] || continue
            skill_name="$(basename "${skill_link}")"
            if [[ -L "${skill_link}" ]]; then
                if [[ "$(readlink "${skill_link}")" != "../../.claude/skills/${skill_name}" ||
                    ! -f "${skill_link}/SKILL.md" ]]; then
                    echo "  .agents/skills/${skill_name} must link to ../../.claude/skills/${skill_name}"
                    ok=false
                    continue
                fi
            elif [[ -e "${ROOT}/.claude/skills/${skill_name}" ]]; then
                echo "  .agents/skills/${skill_name} is a copy; link it to ../../.claude/skills/${skill_name}"
                ok=false
                continue
            fi
            if [[ -f "${skill_link}/SKILL.md" ]] &&
                grep -Eq 'subagent_type|Task\(' "${skill_link}/SKILL.md"; then
                echo "  .agents/skills/${skill_name} is a Claude-lead workflow (Task tool)"
                ok=false
            fi
        done
        if [[ ! -L "${skills_dir}/context-loader" ]]; then
            echo "  .agents/skills/context-loader is missing"
            ok=false
        fi
    fi

    if [[ ! -f "${ROOT}/.claude/settings.json" ]] ||
        ! grep -Fq '.claude/hooks/' "${ROOT}/.claude/settings.json" ||
        grep -Fq '.agents/hooks/' "${ROOT}/.claude/settings.json"; then
        echo "  Claude settings must reference .claude/hooks directly"
        ok=false
    fi
    if [[ ! -f "${ROOT}/.codex/config.toml" ]] ||
        ! grep -Fq '.claude/hooks/log-cli-tools.py' "${ROOT}/.codex/config.toml" ||
        grep -Fq '.codex/skills/' "${ROOT}/.codex/config.toml"; then
        echo "  Codex config must reference canonical .claude hooks directly"
        ok=false
    fi

    ${ok}
}
check "Native runtime boundaries" check_native_boundaries

# --------------------------------------------------------------------------
# 7b) Every script Claude settings run exists: a hook pointing at a removed
#     file fails on every event it is registered for.
# --------------------------------------------------------------------------
check_settings_references() {
    local settings="${ROOT}/.claude/settings.json"
    [[ -f "${settings}" ]] || return 0
    local ok=true reference
    while IFS= read -r reference; do
        [[ -z "${reference}" ]] && continue
        if [[ ! -e "${ROOT}/${reference}" ]]; then
            echo "  .claude/settings.json references a missing file: ${reference}"
            ok=false
        fi
    done < <(grep -oE '\.claude/[A-Za-z0-9_./-]+\.(py|sh)' "${settings}" | sort -u || true)
    ${ok}
}
check "Settings reference existing scripts" check_settings_references

# --------------------------------------------------------------------------
# 8) Bundled skill scripts and the docs that invoke them stay in sync:
#    every script path named in shared markdown exists, and every bundled
#    script is reachable from at least one document.
# --------------------------------------------------------------------------
check_skill_scripts() {
    local ok=true
    # Generated content is not documentation: run logs, checkpoints, project
    # research, and review notes can quote any path and must not drive this
    # check. Review notes in particular record audit findings and proposals, so
    # they name scripts that do not exist yet by design.
    local -a doc_scope=(
        --include='*.md'
        --exclude-dir=logs
        --exclude-dir=checkpoints
        --exclude-dir=research
        --exclude-dir=reviews
    )

    # 8a) Every .claude/skills/**.py|.sh path mentioned in shared markdown resolves.
    local referenced
    referenced=$(grep -rhoE "${doc_scope[@]}" '\.claude/skills/[A-Za-z0-9_/-]+\.(py|sh)' \
        "${ROOT}/.claude" "${ROOT}/.agents" "${ROOT}/.codex" 2>/dev/null | sort -u || true)
    referenced+=$'\n'
    referenced+=$(grep -rhoE '\.claude/skills/[A-Za-z0-9_/-]+\.(py|sh)' \
        "${ROOT}/AGENTS.md" "${ROOT}/README.md" 2>/dev/null | sort -u || true)
    local ref
    while IFS= read -r ref; do
        [[ -z "${ref}" ]] && continue
        if [[ ! -f "${ROOT}/${ref}" ]]; then
            echo "  Documented script does not exist: ${ref}"
            ok=false
        fi
    done <<< "$(echo "${referenced}" | sort -u)"

    # 8b) Every bundled script is documented somewhere, so orphans surface.
    #     Matching on the bare filename is enough: a script's own directory
    #     README refers to it by name, while callers use the full path.
    local script
    while IFS= read -r script; do
        [[ -z "${script}" ]] && continue
        local rel="${script#"${ROOT}/"}"
        local skill_entry
        skill_entry="$(cut -d/ -f1-3 <<< "${rel}")"
        is_template_entry "${skill_entry}" || continue
        if ! grep -rqF "${doc_scope[@]}" "$(basename "${rel}")" \
            "${ROOT}/.claude" "${ROOT}/.agents" "${ROOT}/README.md" 2>/dev/null; then
            echo "  Bundled script is not documented in any markdown: ${rel}"
            ok=false
        fi
    done < <(find "${ROOT}/.claude/skills" -type f \( -name '*.py' -o -name '*.sh' \) | sort)

    ${ok}
}
check "Skill scripts and docs in sync" check_skill_scripts

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
