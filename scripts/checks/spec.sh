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
mg_require_config

doc_file="${1:-}"
[ -n "$doc_file" ] && [ -f "$doc_file" ] || mg_die "検査する文書を指定する"
doc="$(cat "$doc_file")"

merge_base="$(mg_merge_base "${2:-}")" || exit 2

# 分岐元からの変更と、まだ git に追加していないファイルを合わせて「このブランチの変更」とする。
# 承認を記録する時点では、受け入れテストは書かれただけで追加もコミットもされていないことが多い。
tracked_changes="$(mg_name_status "$merge_base")"
untracked="$(mg_untracked_paths)"

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
#
# 「採らなかった案」を必須にしているのは、却下の判断が仕様のほかに残る場所を持たないからである。
# 書かれていないと、作業を引き継いだ側が同じ案をもう一度持ち出し、人間が同じ判断を繰り返すことになる。
REQUIRED_SECTIONS="要件
受け入れ条件
異常系と境界値
対象外
採らなかった案
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

# 条件とテストは、仕様に書いたテストの名前で対応づける。テストの側に条件を指す目印を書かせないのは、
# 仕様が PR の本文にしか残らず、マージ後のテストに残った目印が何を指すのかを読み取れなくなるからである。

# spec_conditions: 標準入力の節の本文から、条件とテストの名前を「C<TAB>条件」「T<TAB>テストの名前」の行で出力する。
# 行頭から始まる箇条書きの項目を 1 つの条件とし、次の項目までの行をその条件の続きとして扱う。
# テストの名前は、「テスト:」のあとにバッククォートで囲んで書かれたものを取り出す。
spec_conditions() {
  awk '
    function emit_tests(line,    at, rest, from, to) {
      at = index(line, "テスト:")
      if (at == 0) at = index(line, "テスト：")
      if (at == 0) return
      rest = substr(line, at)
      while ((from = index(rest, "`")) > 0) {
        rest = substr(rest, from + 1)
        to = index(rest, "`")
        if (to == 0) break
        if (to > 1) print "T\t" substr(rest, 1, to - 1)
        rest = substr(rest, to + 1)
      }
    }
    /^([-*+]|[0-9]+[.)])[ \t]/ {
      in_item = 1
      text = $0
      sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", text)
      print "C\t" text
      emit_tests($0)
      next
    }
    in_item { emit_tests($0) }
  '
}

if ! printf '%s\n' "$doc" | mg_section_body "受け入れ条件" | spec_conditions | grep -q '^C'; then
  problem "受け入れ条件が箇条書きになっていない。条件を 1 つずつ「- 」で始まる行に書く"
fi

# 対応を探すのは、このブランチで追加された行だけにする。分岐元にすでにあるテストが同じ名前でも、
# 今回の条件を検証するために書かれた根拠にはならない。
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

condition=""
condition_has_test=1
require_test_for_condition() {
  if [ -n "$condition" ] && [ "$condition_has_test" -eq 0 ]; then
    problem "条件「${condition}」に対応するテストが書かれていない。条件の下に「テスト: \`テストの名前\`」と書く"
  fi
}

while IFS="$(printf '\t')" read -r kind text; do
  case "$kind" in
    C)
      require_test_for_condition
      condition="$text"
      condition_has_test=0
      ;;
    T)
      condition_has_test=1
      if ! printf '%s\n' "$added_test_lines" | grep -qF -- "$text"; then
        problem "条件「${condition}」のテスト「${text}」が、このブランチで追加したテストにない"
      fi
      ;;
  esac
done <<EOF
$( (
  printf '%s\n' "$doc" | mg_section_body "受け入れ条件"
  printf '%s\n' "$doc" | mg_section_body "異常系と境界値"
) | spec_conditions)
EOF
require_test_for_condition

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
