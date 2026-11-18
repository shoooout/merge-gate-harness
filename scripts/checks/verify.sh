#!/bin/bash
# 対象リポジトリの .merge-gate.json に書かれた検査コマンド(テスト・型検査・ビルドなど)を実行する。
# Stop hook と CI が同じこのスクリプトを呼ぶので、手元で通ったものが CI で落ちるずれが起きない。
#
# 使い方: verify.sh [--ci]
#   --ci  checks.verify に加えて checks.ci も実行する。mutation testing や SAST のように
#         時間がかかり、作業の終了のたびには走らせられない検査を置く。
# 終了コード: 0 = すべて成功、1 = 失敗した検査がある、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

WITH_CI=0
[ "${1:-}" = "--ci" ] && WITH_CI=1

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

commands="$(mg_config '.checks.verify[]?')"
if [ "$WITH_CI" -eq 1 ]; then
  commands="$commands
$(mg_config '.checks.ci[]?')"
fi

log="$(mktemp "${TMPDIR:-/tmp}/merge-gate-verify.XXXXXX")"
trap 'rm -f "$log"' EXIT

failed=0
ran=0
while IFS= read -r command; do
  [ -n "$command" ] || continue
  ran=$((ran + 1))
  if (cd "$MG_ROOT" && bash -c "$command") >"$log" 2>&1 </dev/null; then
    echo "ok: $command"
  else
    failed=$((failed + 1))
    echo "失敗: $command"
    # 出力の全量を返すと hook 経由でエージェントの文脈を埋めるので、原因が載りやすい末尾だけ返す
    tail -n 60 "$log" | sed 's/^/    /'
  fi
done <<EOF
$commands
EOF

if [ "$ran" -eq 0 ]; then
  # 検査が 1 つもないまま「成功」を返すと、何も検証していない変更が通ってしまう
  mg_die "$MG_CONFIG_NAME の checks.verify が空で、実行する検査がない"
fi

[ "$failed" -eq 0 ]
