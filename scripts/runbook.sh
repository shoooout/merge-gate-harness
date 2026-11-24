#!/bin/bash
# 動作確認の手引きを、対象リポジトリにファイルを足さずに保存する。
# 手引きは、アプリの起動のしかた、確認に使う画面やコマンド、ログインの手段のように、
# 実物を動かして確かめるために毎回必要になる知識である。残しておかないと、エージェントは
# 引き継ぎのたびに調べ直し、調べきれなかった手順が「実行できなかった」として人間に回る。
#
# 保存先は検査の設定と同じ git のディレクトリで、コミットされず、worktree の間で共有される。
# 検査の強さを左右しないので、検査の設定と違って、編集に人間の確認は求めない。
#
# 使い方:
#   runbook.sh path           手引きのパスを出力する。手引きがまだなくても、保存先を出力する
#   runbook.sh show           手引きの内容を出力する
#   runbook.sh set [ファイル]  手引きを保存する。ファイルを省略すると標準入力を読む
# 終了コード: 0 = 成功、1 = show で手引きがない、2 = 使い方や内容の問題
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
RUNBOOK="$(mg_git_common_dir)/merge-gate/runbook.md"

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  path)
    printf '%s\n' "$RUNBOOK"
    ;;
  show)
    [ -f "$RUNBOOK" ] || exit 1
    cat "$RUNBOOK"
    ;;
  set)
    content="$(cat "${1:-/dev/stdin}")" || mg_die "手引きを読めない: ${1:-標準入力}"
    printf '%s' "$content" | grep -q '[^[:space:]]' || mg_die "手引きが空である"
    mkdir -p "$(dirname "$RUNBOOK")" || mg_die "保存先を作れない: $(dirname "$RUNBOOK")"
    if ! printf '%s\n' "$content" >"$RUNBOOK.tmp" || ! mv "$RUNBOOK.tmp" "$RUNBOOK"; then
      mg_die "手引きを保存できない: $RUNBOOK"
    fi
    echo "保存: $RUNBOOK"
    ;;
  *)
    mg_die "使い方: runbook.sh path | show | set [ファイル]"
    ;;
esac
