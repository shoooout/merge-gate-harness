#!/bin/bash
# このブランチで追加された行に、秘密の値らしい文字列がないかを検査する。
# 一度コミットされた秘密の値は、あとで消しても履歴に残る。そのため人間の承認では通さず、必ず失敗にする。
#
# 見つけた値そのものは出力しない。出力は hook 経由でエージェントの文脈に入り、CI のログにも残るためである。
#
# 使い方: secrets.sh [比較元の ref]
# 終了コード: 0 = 見つからない、1 = 見つかった、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

merge_base="$(mg_merge_base "${1:-}")" || exit 2

# 発行元が形式を決めていて、偶然の一致がほとんど起きないものだけを組み込みにする。
# 「password = 」のような一般的な形は誤検知が多く、検査そのものが信用されなくなるので入れない。
# 組織固有の形式は、対象リポジトリの設定の secret_patterns で足す。
TAB="$(printf '\t')"
patterns=""
add_pattern() {
  patterns="$patterns$1$TAB$2
"
}
add_pattern "秘密鍵" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
add_pattern "AWS のアクセスキー" '(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Z0-9]|$)'
add_pattern "GitHub のトークン" 'gh[pousr]_[A-Za-z0-9]{36,}'
add_pattern "GitHub のトークン" 'github_pat_[A-Za-z0-9_]{22,}'
add_pattern "Slack のトークン" 'xox[abprs]-[A-Za-z0-9-]{10,}'
add_pattern "Google の API キー" 'AIza[0-9A-Za-z_-]{35}'
add_pattern "Stripe の秘密鍵" '[sr]k_live_[0-9A-Za-z]{24,}'
add_pattern "Anthropic の API キー" 'sk-ant-[A-Za-z0-9_-]{20,}'
add_pattern "OpenAI の API キー" 'sk-(proj-)?[A-Za-z0-9_-]{40,}'

while IFS= read -r extra; do
  [ -n "$extra" ] || continue
  add_pattern "設定で指定した形式" "$extra"
done <<EOF
$(mg_config '.secret_patterns[]?')
EOF

# テスト用の偽の値を置くファイルなど、対象リポジトリが除外すると決めたパスは検査しない
ignore_patterns="$(mg_config '.paths.secrets_ignore[]?')"
added_lines="$(mg_added_lines "$merge_base" | while IFS= read -r row; do
  path="${row%%"$TAB"*}"
  if [ -n "$ignore_patterns" ] && mg_match_patterns "$path" "$ignore_patterns"; then
    continue
  fi
  printf '%s\n' "$row"
done)"

found=0
while IFS="$TAB" read -r label pattern; do
  [ -n "$pattern" ] || continue
  hits="$(mg_grep_added "$added_lines" "$pattern")" || continue
  while IFS= read -r hit; do
    echo "秘密の値らしい文字列が追加されている: $hit ($label)"
    found=$((found + 1))
  done <<EOF
$hits
EOF
done <<EOF
$patterns
EOF

if [ "$found" -gt 0 ]; then
  echo "値を環境変数や秘密情報の管理の仕組みに移すこと。すでにコミットした場合は、値そのものを無効にして発行し直す必要がある。"
  exit 1
fi
exit 0
