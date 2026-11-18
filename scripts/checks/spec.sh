#!/bin/bash
# 仕様が、承認と検証に耐える形で書かれているかを検査する。
# 仕様の内容が正しいかどうかは機械的には決められない。ここで確かめるのは、人間が判断するための材料が
# 揃っていることと、受け入れ条件とテストの対応を追えることである。
#
# 仕様の文書と PR の本文のどちらにも使う。手元では承認を記録する前と作業の終了時に、CI では PR の本文に
# 対して実行する。PR の本文に仕様がなければ CI が落ちるので、仕様の承認を経ずに実装した変更を検知できる。
#
# 使い方: spec.sh <仕様の文書または PR の本文のファイル> [比較元の ref]
# 終了コード: 0 = 問題なし、1 = 不備がある、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

doc_file="${1:-}"
[ -n "$doc_file" ] && [ -f "$doc_file" ] || mg_die "検査する文書を指定する"
doc="$(cat "$doc_file")"

merge_base="$(mg_merge_base "${2:-}")" || exit 2

# 分岐元からの変更と、まだ git に追加していないファイルを合わせて「このブランチの変更」とする。
# 承認を記録する時点では、受け入れテストは書かれただけで追加もコミットもされていないことが多い。
tracked_changes="$(git -C "$MG_ROOT" diff --name-status --no-renames "$merge_base" --)"
untracked="$(git -C "$MG_ROOT" ls-files -o --exclude-standard)"

all_paths="$(printf '%s\n' "$tracked_changes" | cut -f2)
$untracked"

# ドキュメントだけの変更のように、仕様を要しないと対象リポジトリが決めたパスだけの変更は検査しない。
no_spec_patterns="$(mg_config '.paths.no_spec[]?')"
if [ -n "$no_spec_patterns" ]; then
  needs_spec=0
  changed_any=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    changed_any=1
    mg_match_patterns "$path" "$no_spec_patterns" || needs_spec=1
  done <<EOF
$all_paths
EOF
  if [ "$changed_any" -eq 1 ] && [ "$needs_spec" -eq 0 ]; then
    exit 0
  fi
fi

problems=0
problem() {
  echo "$1"
  problems=$((problems + 1))
}

# ---- 人間が判断するための材料が揃っているか

# 「依頼と食い違う点」「確認できていない前提」を必須にしているのは、依頼の内容が正しいとは限らないからである。
# 該当がない場合も、何を確かめたうえで「なし」なのかを書かせる。節ごと省かれると、確かめたのかどうかが分からない。
REQUIRED_SECTIONS="要件
受け入れ条件
異常系と境界値
対象外
依頼と食い違う点
確認できていない前提
変更する既存テスト"

while IFS= read -r section; do
  if ! printf '%s\n' "$doc" | mg_section_has_content "$section"; then
    problem "仕様に「${section}」の節がないか、中身が空になっている"
  fi
done <<EOF
$REQUIRED_SECTIONS
EOF

# ---- 受け入れ条件とテストの対応を追えるか

ids="$( (
  printf '%s\n' "$doc" | mg_section_body "受け入れ条件"
  printf '%s\n' "$doc" | mg_section_body "異常系と境界値"
) | grep -oE 'AC-[0-9]+' | sort -u)"

if ! printf '%s\n' "$doc" | mg_section_body "受け入れ条件" | grep -qE 'AC-[0-9]+'; then
  problem "受け入れ条件に AC-1 のような番号が付いていない"
fi

# 対応を探すのは、このブランチで追加された行だけにする。過去の変更で付けられた同じ番号が
# テストに残っていても、今回の条件を検証している根拠にはならない。
added_test_lines=""
existing_tests_changed=""
while IFS="$(printf '\t')" read -r status path; do
  [ -n "$path" ] || continue
  mg_match "$path" tests || continue
  if [ "$status" != "A" ]; then
    existing_tests_changed="$existing_tests_changed$path
"
  fi
  [ "$status" = "D" ] && continue
  added_test_lines="$added_test_lines$(git -C "$MG_ROOT" diff -U0 "$merge_base" -- "$path" | grep '^+' | grep -v '^+++')
"
done <<EOF
$tracked_changes
EOF

while IFS= read -r path; do
  [ -n "$path" ] || continue
  mg_match "$path" tests || continue
  added_test_lines="$added_test_lines$(cat "$MG_ROOT/$path")
"
done <<EOF
$untracked
EOF

while IFS= read -r id; do
  [ -n "$id" ] || continue
  # AC-1 が AC-10 に一致しないよう、番号の直後が数字でないことを確かめる
  if ! printf '%s\n' "$added_test_lines" | grep -qE "(^|[^A-Za-z0-9])${id}([^0-9]|\$)"; then
    problem "${id} に対応するテストがない。対応するテストの名前かコメントに ${id} と書く"
  fi
done <<EOF
$ids
EOF

# ---- 既存テストの変更が、承認時に示されていたか

# 既存テストの変更が必要になるのは、依頼が過去に決めた挙動と食い違っている場合が多い。
# 承認の時点で人間に見せていない既存テストの変更を、あとから紛れ込ませないようにする。
listed="$(printf '%s\n' "$doc" | mg_section_body "変更する既存テスト")"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! printf '%s\n' "$listed" | grep -qF -- "$path"; then
    problem "既存のテスト $path を変更しているが、仕様の「変更する既存テスト」に挙げられていない"
  fi
done <<EOF
$existing_tests_changed
EOF

[ "$problems" -eq 0 ]
