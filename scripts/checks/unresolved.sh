#!/bin/bash
# Stop hook が、検査の通らないまま作業の終了を許したときの記録を出力する。
# 終了を許した事実は、エージェントが報告しない限り人間に伝わらない。PR の「検証できなかったこと」に
# 転記させるために、記録を読み出す手段を用意している。
#
# 使い方: unresolved.sh
# 出力: 終了を許した理由と、そのとき通っていなかった検査の出力。記録がなければ何も出力しない。
# 終了コード: 0 = 記録がない、1 = 記録がある、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"

record="$(mg_hook_state_dir)/unresolved"
[ -f "$record" ] || exit 0

# 記録の 1 行目は、記録を取ったブランチである。承認の記録と同じく、別のブランチの記録は無いものとして扱う。
[ "$(sed -n 1p "$record")" = "$(mg_current_branch)" ] || exit 0

sed 1d "$record"
exit 1
