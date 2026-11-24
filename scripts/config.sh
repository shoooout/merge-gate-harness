#!/bin/bash
# 検査の設定を、対象リポジトリにファイルを足さずに保存する。
# 保存先は git のディレクトリの中で、コミットされず、worktree の間で共有される。
#
# リポジトリに .merge-gate.json がコミットされている場合は、そちらだけが使われる。
# その状態では保存を受け付けない。保存しても使われず、設定を変えたつもりになるだけだからである。
#
# 使い方:
#   config.sh path           使われる設定のパスを出力する。設定がまだなくても、保存先を出力する
#   config.sh show           使われる設定の内容を出力する
#   config.sh set [ファイル]  設定を検査してから保存する。ファイルを省略すると標準入力を読む
# 終了コード: 0 = 成功、1 = show で設定がない、2 = 使い方や設定の内容の問題
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  path)
    printf '%s\n' "$MG_CONFIG"
    ;;
  show)
    mg_has_config || exit 1
    cat "$MG_CONFIG"
    ;;
  set)
    [ ! -f "$MG_ROOT/$MG_CONFIG_NAME" ] ||
      mg_die "リポジトリに $MG_CONFIG_NAME があり、そちらが使われる。設定を変えるには、そのファイルを変更する"

    content="$(cat "${1:-/dev/stdin}")" || mg_die "設定を読めない: ${1:-標準入力}"
    printf '%s' "$content" | jq -e 'type == "object"' >/dev/null 2>&1 ||
      mg_die "設定が JSON のオブジェクトになっていない"
    # 検査のコマンドが 1 つもない設定を受け付けると、何も検証しないまま作業の終了を通すことになる。
    printf '%s' "$content" | jq -e '
      (.checks.verify | type == "array" and length > 0)
      and (.checks.verify | all(type == "string" and length > 0))
    ' >/dev/null 2>&1 ||
      mg_die "checks.verify に、検査のコマンドを 1 つ以上、文字列の配列で指定する"

    target="$(mg_local_config_path)"
    mkdir -p "$(dirname "$target")" || mg_die "保存先を作れない: $(dirname "$target")"
    if ! printf '%s\n' "$content" | jq . >"$target.tmp" || ! mv "$target.tmp" "$target"; then
      mg_die "設定を保存できない: $target"
    fi
    mg_ensure_state_ignored
    echo "保存: $target"
    ;;
  *)
    mg_die "使い方: config.sh path | show | set [ファイル]"
    ;;
esac
