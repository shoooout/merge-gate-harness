#!/bin/bash
# 手元で、この変更を人間が diff を読まずにマージしてよいかを判定し、PR の本文に載せる報告を出力する。
# ハーネス専用の CI を置かないリポジトリでは、この報告が、人間が diff を読むかどうかを決める材料になる。
#
# classify.sh と違い、手元にしかない記録も読む。仕様の承認の記録と、承認の時点でテストが落ちたかの記録である。
# CI にはこれらの記録がないので、CI からは呼ばない。
#
# 報告には、使った検査のコマンドも載せる。リポジトリの外に置いた設定は PR のレビューを通らないので、
# 検査が弱められていても、ここに出なければ人間が気づく手段がない。
#
# 使い方: gate.sh [比較元の ref]
# 終了コード: 0 = diff を読まずにマージしてよい、3 = 人間の確認が必要、
#             1 = 人間の承認があっても通してはいけない不備がある、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CHECKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_require_config

merge_base="$(mg_merge_base "${1:-}")" || exit 2

reasons="$(cd "$MG_ROOT" && bash "$CHECKS_DIR/classify.sh" "${1:-}")"
classify_status=$?
if [ "$classify_status" -ne 0 ] && [ "$classify_status" -ne 3 ]; then
  printf '%s\n' "$reasons"
  exit "$classify_status"
fi

add_reason() {
  reasons="$(printf '%s\n%s' "$reasons" "$1" | sed '/^$/d')"
}

# テストが変更を検出することの記録を確かめる。実装に当たる変更がなければ、検出すべきものがない。
if [ -n "$(mg_implementation_changes "$merge_base")" ]; then
  red_file="$MG_ROOT/$MG_STATE_DIR/red"
  if ! mg_lock_is_current; then
    add_reason "仕様と受け入れテストの承認の記録が、このブランチにない。テストがこの変更を検出するかを確かめていない"
  elif [ ! -f "$red_file" ]; then
    add_reason "実装の前に検査が落ちたかの記録がない。テストがこの変更を検出するかを確かめていない"
  else
    case "$(sed -n 1p "$red_file")" in
      detected) ;;
      disabled) add_reason "テストが変更を検出するかの確認が、設定の checks.red で無効にされている" ;;
      *) add_reason "実装の前に、検査がすべて通っていた。この変更を検出するテストがない" ;;
    esac
  fi
fi

if ! (cd "$MG_ROOT" && bash "$CHECKS_DIR/unresolved.sh") >/dev/null 2>&1; then
  add_reason "検査が通らないまま、作業の終了を許した記録がある"
fi

secrets_output="$(cd "$MG_ROOT" && bash "$CHECKS_DIR/secrets.sh" "${1:-}" 2>&1)"
secrets_status=$?
if [ "$secrets_status" -ne 0 ] && [ "$secrets_status" -ne 1 ]; then
  printf '%s\n' "$secrets_output"
  exit "$secrets_status"
fi

if [ "$secrets_status" -eq 1 ]; then
  echo "マージしてはいけない。人間の承認があっても通さない不備がある。"
  printf '%s\n' "$secrets_output" | sed 's/^/- /'
  echo ""
fi

if [ -n "$reasons" ]; then
  echo "人間が diff を確認する必要がある。"
  printf '%s\n' "$reasons" | sed 's/^/- /'
else
  echo "人間が diff を確認する理由は見つからなかった。"
fi

echo ""
if [ "$MG_CONFIG" = "$MG_ROOT/$MG_CONFIG_NAME" ]; then
  echo "検査の設定は、リポジトリの $MG_CONFIG_NAME を使った。"
else
  echo "検査の設定は、リポジトリの外に置いたものを使った。この設定は PR のレビューを通っていない。"
fi
mg_config '.checks.verify[]?' | sed 's/^/- 終了時に実行した検査: `/; s/$/`/'
mg_config '.paths.tests[]?' | sed 's/^/- テストとして扱ったパス: `/; s/$/`/'

[ "$secrets_status" -eq 0 ] || exit 1
[ -z "$reasons" ] || exit 3
exit 0
