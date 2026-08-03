#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: resolve_packet.sh <task-id>" >&2
  exit 64
fi

task_id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "status=blocked"
  echo "reason=not_in_git_checkout"
  exit 2
}
primary_root="$(dirname "$git_common_dir")"
if [[ "$(git -C "$primary_root" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]]; then
  primary_root="$(git rev-parse --show-toplevel)"
fi

if [[ -d "$primary_root/sanad-agent/.agents/skills" ]]; then
  sanad_root="$primary_root/sanad-agent"
elif [[ -d "$primary_root/.agents/skills" ]]; then
  sanad_root="$primary_root"
elif [[ -d "$(git rev-parse --show-toplevel 2>/dev/null)/.agents/skills" ]]; then
  sanad_root="$(git rev-parse --show-toplevel)"
else
  echo "status=blocked"
  echo "reason=sanad_root_not_found"
  exit 2
fi

reference_root="$sanad_root/refrence_projects"
evidence_root="$reference_root/.sanad-evidence"

if ! git -C "$primary_root" check-ignore -q "$evidence_root"; then
  echo "status=blocked"
  echo "reason=evidence_store_not_ignored"
  exit 4
fi

mkdir -p "$evidence_root/packets" "$evidence_root/runs"
index_file="$evidence_root/packet-index.tsv"
catalog_file="$evidence_root/source-catalog.tsv"
packet_sources_file="$evidence_root/packet-sources.tsv"
audit_index_file="$evidence_root/audit-index.tsv"
touch "$index_file" "$catalog_file" "$packet_sources_file" "$audit_index_file"

packet_rel="$(
  awk -F $'\t' -v wanted="$task_id" '$1 == wanted { print $2; found = 1 } END { if (!found) exit 1 }' "$index_file"
)" || {
  echo "status=authoring_required"
  echo "reason=packet_not_registered"
  echo "task_id=$task_id"
  echo "evidence_root=$evidence_root"
  exit 10
}
packet_path="$evidence_root/$packet_rel"

if [[ ! -f "$packet_path" ]]; then
  echo "status=authoring_required"
  echo "reason=packet_file_missing"
  echo "task_id=$task_id"
  echo "packet=$packet_path"
  exit 10
fi

source_rows="$(
  awk -F $'\t' -v wanted="$task_id" '$1 == wanted { print; found = 1 } END { if (!found) exit 1 }' "$packet_sources_file"
)" || {
  echo "status=authoring_required"
  echo "reason=packet_sources_missing"
  echo "task_id=$task_id"
  exit 10
}

while IFS=$'\t' read -r mapped_task source_id expected_revision; do
  [[ -z "$mapped_task" || "$mapped_task" == \#* ]] && continue
  catalog_row="$(
    awk -F $'\t' -v wanted="$source_id" '$1 == wanted { print; found = 1 } END { if (!found) exit 1 }' "$catalog_file"
  )" || {
    echo "status=authoring_required"
    echo "reason=source_catalog_entry_missing"
    echo "task_id=$task_id"
    echo "source_id=$source_id"
    exit 10
  }
  IFS=$'\t' read -r _source_id source_rel remote_url <<< "$catalog_row"
  source_path="$sanad_root/$source_rel"

  case "$source_path" in
    "$reference_root"/*) ;;
    *)
      echo "status=blocked"
      echo "reason=source_path_outside_reference_directory"
      echo "source_id=$source_id"
      exit 4
      ;;
  esac

  if [[ ! -d "$source_path/.git" ]]; then
    if [[ -e "$source_path" ]]; then
      echo "status=blocked"
      echo "reason=source_path_is_not_git_repository"
      echo "source_id=$source_id"
      exit 12
    fi
    if [[ -z "$remote_url" ]]; then
      echo "status=source_unavailable"
      echo "reason=source_remote_missing"
      echo "source_id=$source_id"
      exit 12
    fi
    if [[ "$remote_url" == *"@"* ]] || {
      [[ "$remote_url" != https://* ]] &&
      [[ "$remote_url" != http://* ]] &&
      [[ "$remote_url" != git://* ]]
    }; then
      echo "status=source_unavailable"
      echo "reason=automatic_clone_requires_public_credential_free_url"
      echo "source_id=$source_id"
      exit 12
    fi
    mkdir -p "$(dirname "$source_path")"
    if ! git clone --no-checkout -- "$remote_url" "$source_path" >&2; then
      echo "status=source_unavailable"
      echo "reason=source_clone_failed"
      echo "source_id=$source_id"
      exit 12
    fi
    if ! git -C "$source_path" checkout --detach "$expected_revision" >&2; then
      git -C "$source_path" fetch origin "$expected_revision" >&2 || true
      if ! git -C "$source_path" checkout --detach "$expected_revision" >&2; then
        echo "status=source_unavailable"
        echo "reason=pinned_revision_unavailable"
        echo "source_id=$source_id"
        exit 12
      fi
    fi
  fi

  actual_revision="$(git -C "$source_path" rev-parse HEAD 2>/dev/null)" || {
    echo "status=source_unavailable"
    echo "reason=source_revision_unreadable"
    echo "source_id=$source_id"
    exit 12
  }
  if [[ "$actual_revision" != "$expected_revision" ]]; then
    echo "status=refresh_required"
    echo "reason=source_revision_changed"
    echo "task_id=$task_id"
    echo "source_id=$source_id"
    echo "expected_revision=$expected_revision"
    echo "actual_revision=$actual_revision"
    exit 11
  fi
  if [[ -n "$(git -C "$source_path" status --short)" ]]; then
    echo "warning=source_worktree_dirty"
    echo "source_id=$source_id"
  fi
done <<< "$source_rows"

if command -v shasum >/dev/null 2>&1; then
  fingerprint="$(shasum -a 256 "$packet_path" | awk '{print $1}')"
else
  fingerprint="$(sha256sum "$packet_path" | awk '{print $1}')"
fi

echo "status=ready"
echo "task_id=$task_id"
echo "packet=$packet_path"
echo "fingerprint=sha256:$fingerprint"
echo "run_records=$evidence_root/runs"
while IFS=$'\t' read -r task_prefix audit_rel; do
  [[ -z "$task_prefix" || "$task_prefix" == \#* ]] && continue
  if [[ "$task_id" == "$task_prefix"* && -f "$evidence_root/$audit_rel" ]]; then
    echo "navigation_aid=$evidence_root/$audit_rel"
  fi
done < "$audit_index_file"
