#!/bin/bash
# いまの作業ツリーの変更の識別子を、PR の本文に書く形で出力する。
# 出力した行を本文に写すと、その本文の検証の結果が、どの変更に対するものかを示せる。
# 本文との照合は checks/handoff.sh が行う。
#
# 使い方: change-id.sh [比較元の ref]
# 終了コード: 0 = 成功、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

merge_base="$(mg_merge_base "${1:-}")" || exit 2
after="$(mg_worktree_tree)" || mg_die "作業ツリーの内容を読めない"
change_id="$(mg_change_id "$merge_base" "$after")" || mg_die "変更の識別子を計算できない"
mg_change_marker "$change_id"
