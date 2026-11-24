#!/bin/bash
# このブランチの変更を、人間が diff を見なくてもマージしてよいかどうかに分類する。
# 判定はパスと差分だけで機械的に決まり、LLM の判断を含まない。
#
# 使い方: classify.sh [比較元の ref]
# 出力: 人間に回す理由を 1 行ずつ。理由がなければ何も出力しない。
# 終了コード: 0 = 自動マージしてよい、3 = 人間の確認が必要、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

merge_base="$(mg_merge_base "${1:-}")" || exit 2

reasons=""
add_reason() {
  reasons="$reasons$1
"
}

# rename は「元のパスの削除」と「新しいパスの追加」の両方として扱う。
# 既存テストを別名に移してから書き換える形で、テストの変更検知をすり抜けられないようにする。
changes="$(mg_name_status "$merge_base")"

test_files=""
while IFS="$(printf '\t')" read -r status path; do
  [ -n "$path" ] || continue

  if mg_is_gate_path "$path"; then
    add_reason "ゲートの定義を変更している: $path"
  fi
  if mg_match "$path" dependencies; then
    add_reason "依存の定義を変更している: $path"
  fi
  if mg_match "$path" human_review; then
    add_reason "人間が確認すると決めたパスを変更している: $path"
  fi

  if mg_match "$path" tests; then
    case "$status" in
      D) add_reason "既存のテストを削除している: $path" ;;
      A) test_files="$test_files$path
" ;;
      *)
        add_reason "既存のテストを変更している: $path"
        test_files="$test_files$path
"
        ;;
    esac
  fi
done <<EOF
$changes
EOF

# 追加された行に skip の印があれば、テストを無効にして通した可能性がある。
# 新規のテストファイルも対象にする。最初から skip されたテストは何も検証しない。
markers="$(mg_config '.skip_markers[]?')"
if [ -n "$markers" ] && [ -n "$test_files" ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    added="$(git -C "$MG_ROOT" diff -U0 "$merge_base" -- "$path" | grep '^+' | grep -v '^+++')"
    [ -n "$added" ] || continue
    while IFS= read -r marker; do
      [ -n "$marker" ] || continue
      if printf '%s\n' "$added" | grep -Eq -- "$marker"; then
        add_reason "テストを skip する記述を追加している: $path ($marker)"
      fi
    done <<EOF
$markers
EOF
  done <<EOF
$test_files
EOF
fi

# lint や型検査の抑制のように、検査を黙らせる記述が追加されていれば人間に回す。
# 検査が通ったという事実は、その検査が黙らされていないことを前提にしている。
# 何が抑制に当たるかはツールごとに違うので、ここには一覧を持たず、対象リポジトリの設定から読む。
review_markers="$(mg_config '.review_markers[]?')"
if [ -n "$review_markers" ]; then
  added_lines="$(mg_added_lines "$merge_base")"
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    hits="$(mg_grep_added "$added_lines" "$marker")" || continue
    while IFS= read -r hit; do
      add_reason "人間が確認すると決めた記述を追加している: $hit ($marker)"
    done <<EOF
$hits
EOF
  done <<EOF
$review_markers
EOF
fi

max_lines="$(mg_config '.limits.max_changed_lines')"
if [ -n "$max_lines" ]; then
  # バイナリは numstat が "-" を返すので行数に数えない
  changed_lines="$(git -C "$MG_ROOT" diff --numstat "$merge_base" -- |
    awk '$1 != "-" { total += $1 + $2 } END { print total + 0 }')"
  if [ "$changed_lines" -gt "$max_lines" ]; then
    add_reason "変更行数 $changed_lines が上限 $max_lines を超えている"
  fi
fi

if [ -n "$reasons" ]; then
  printf '%s' "$reasons"
  exit 3
fi
exit 0
