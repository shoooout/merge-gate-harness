#!/bin/bash
# PR の本文に、人間が動作確認をするための情報が書かれているかを検査する。
# 見出しがあるだけで中身が空の節は、書かれていないものとして扱う。
#
# 確かめるのは節があることまでである。「実行した確認」に書かれた結果が事実かどうかは確かめられない。
# それでも節を必須にしているのは、実行したとも実行できなかったとも書かれていない状態をなくすためである。
# 書かれていなければ、人間は、エージェントが実物を動かしたのかどうかを知る手段を持たない。
#
# 使い方: handoff.sh [本文のファイル]   ファイルを省略すると標準入力を読む
# 終了コード: 0 = 必要な節がすべてある、1 = 足りない節がある、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_require_config

body="$(cat "${1:-/dev/stdin}")" || mg_die "本文を読めない: ${1:-標準入力}"

sections="$(mg_config '.handoff_sections[]?')"
[ -n "$sections" ] || sections="動作確認の手順
実行した確認
影響範囲
独立した検証
検証できなかったこと"

missing=0
while IFS= read -r section; do
  [ -n "$section" ] || continue
  if ! printf '%s\n' "$body" | mg_section_has_content "$section"; then
    echo "PR の本文に「${section}」の節がないか、中身が空になっている"
    missing=$((missing + 1))
  fi
done <<EOF
$sections
EOF

[ "$missing" -eq 0 ]
