#!/bin/bash
# PostToolUse hook。編集されたファイルに、対象リポジトリの検査の設定の checks.on_edit で
# 指定された formatter や lint を実行する。失敗した場合は出力をエージェントに返し、その場で直させる。
#
# checks.on_edit の各要素は {"pattern": "<glob>", "command": "<コマンド>"} で、
# コマンドの末尾に、編集されたファイルのルートからの相対パスを引数として付けて実行する。
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$file_path" ] || exit 0

mg_find_root "${cwd:-.}" || exit 0
mg_has_config || exit 0

case "$file_path" in
  /*) ;;
  *) file_path="${cwd:-$PWD}/$file_path" ;;
esac
rel="$(mg_relpath "$file_path")" || exit 0
[ -f "$MG_ROOT/$rel" ] || exit 0

count="$(jq -r '(.checks.on_edit // []) | length' "$MG_CONFIG")"
failed=0
report=""
i=0
while [ "$i" -lt "$count" ]; do
  pattern="$(mg_config ".checks.on_edit[$i].pattern")"
  command="$(mg_config ".checks.on_edit[$i].command")"
  i=$((i + 1))
  [ -n "$pattern" ] && [ -n "$command" ] || continue
  mg_match_patterns "$rel" "$pattern" || continue

  # パスはコマンド文字列に埋め込まず位置引数で渡す。空白や記号を含むファイル名でコマンドが壊れないようにするため。
  if ! output="$(cd "$MG_ROOT" && bash -c "$command"' "$1"' _ "$rel" 2>&1 </dev/null)"; then
    failed=$((failed + 1))
    report="${report}失敗: $command $rel
$(printf '%s\n' "$output" | tail -n 40)
"
  fi
done

if [ "$failed" -gt 0 ]; then
  printf 'merge-gate: 編集後の検査が失敗した。原因を直すこと。\n%s' "$report" >&2
  exit 2
fi
exit 0
