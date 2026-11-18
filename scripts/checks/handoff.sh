#!/bin/bash
# PR の本文に、人間が動作確認をするための情報が書かれているかを検査する。
# 見出しがあるだけで中身が空の節は、書かれていないものとして扱う。
#
# 使い方: handoff.sh [本文のファイル]   ファイルを省略すると標準入力を読む
# 終了コード: 0 = 必要な節がすべてある、1 = 足りない節がある、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

body="$(cat "${1:-/dev/stdin}")" || mg_die "本文を読めない: ${1:-標準入力}"

sections="$(mg_config '.handoff_sections[]?')"
[ -n "$sections" ] || sections="動作確認の手順
影響範囲
検証できなかったこと"

missing=0
while IFS= read -r section; do
  [ -n "$section" ] || continue
  # 対象の見出しから次の見出しまでに、空白と HTML コメント以外の行が 1 つでもあれば中身ありとする。
  # PR テンプレートの説明用コメントだけが残った節を、書かれたものと数えないため。
  if ! printf '%s\n' "$body" | awk -v section="$section" '
    /^#+[ \t]/ {
      inside = (index($0, section) > 0)
      next
    }
    inside && $0 !~ /^[ \t\r]*$/ && $0 !~ /^[ \t]*<!--.*-->[ \t\r]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    echo "PR の本文に「${section}」の節がないか、中身が空になっている"
    missing=$((missing + 1))
  fi
done <<EOF
$sections
EOF

[ "$missing" -eq 0 ]
