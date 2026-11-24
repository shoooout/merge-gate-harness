#!/bin/bash
# PreToolUse hook。エージェントが編集しようとしているファイルが、人間の承認なしに変えてはいけないものなら、
# 編集の前に利用者へ確認を出す。拒否ではなく確認にしているのは、仕様変更に伴うテストの修正のように
# 正当な変更があり、その可否を決められるのは人間だけだからである。
#
# この hook が見るのは編集ツール経由の変更だけで、シェルコマンドによる書き換えは通ってしまう。
# そちらは Stop hook の承認済みファイルの照合と、classify.sh で検知する。classify.sh は、引き継ぎのときの gate.sh とハーネスの CI が呼ぶ。
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$file_path" ] || exit 0

mg_find_root "${cwd:-.}" || exit 0

case "$file_path" in
  /*) ;;
  *) file_path="${cwd:-$PWD}/$file_path" ;;
esac

ask() {
  jq -n --arg reason "merge-gate: $1 ($rel)" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# リポジトリの外に置いた設定は、作業ツリーの外にあることがあり、ルートからの相対パスでは判定できない。
# 設定がまだないときの新規作成も確認する。確認なしで作れると、エージェントが検査の強さを自分で決められる。
rel="$(mg_physical_path "$file_path")" || exit 0
if [ "$rel" = "$(mg_local_config_path)" ]; then
  ask "検査の設定は、人間の承認なしに変更できない"
fi

# 設定のないリポジトリでは、ここから先は何もしない。プラグインを有効にしただけで、関係のないリポジトリの作業を妨げないため。
mg_has_config || exit 0
mg_ensure_state_ignored
rel="$(mg_relpath "$file_path")" || exit 0

if mg_is_gate_path "$rel"; then
  ask "ゲートの定義は、人間の承認なしに変更できない"
fi

if mg_match "$rel" dependencies; then
  ask "依存の追加・削除は、人間の承認なしに行えない"
fi

if mg_locked_paths | grep -qxF -- "$rel"; then
  ask "承認済みの仕様・受け入れテストは、人間の承認なしに変更できない。承認を得たら lock.sh add で記録し直す"
fi

if mg_match "$rel" tests; then
  # このブランチで新しく書いたテストは自由に直せる。止めるのは、分岐元にすでにあったテストだけ。
  # 分岐元を特定できない環境では、最後のコミットにあるかどうかで代用する。
  merge_base="$(mg_merge_base 2>/dev/null)" || merge_base="HEAD"
  if git -C "$MG_ROOT" cat-file -e "$merge_base:$rel" 2>/dev/null; then
    ask "既存のテストは、人間の承認なしに変更できない"
  fi
fi

exit 0
