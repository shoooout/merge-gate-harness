#!/bin/bash
# PR の本文に、人間が動作確認をするための情報が書かれているかを検査する。
# 見出しがあるだけで中身が空の節は、書かれていないものとして扱う。
#
# 確かめるのは節があることまでである。「実行した確認」に書かれた結果が事実かどうかは確かめられない。
# それでも節を必須にしているのは、実行したとも実行できなかったとも書かれていない状態をなくすためである。
# 書かれていなければ、人間は、エージェントが実物を動かしたのかどうかを知る手段を持たない。
#
# 本文に書かれた変更の識別子が、いまの変更と一致するかも確かめる。一致しなければ、本文の検証の結果は
# 別の変更に対するものである。識別子を書くのは本文を書いた側なので、検証をやり直さずに識別子だけを
# 書き換えることは防げない。防げるのは、変更を足したあとに古い結果が黙って残ることである。
#
# 使い方: handoff.sh [--commit <コミット>] [本文のファイル] [比較元の ref]
#   本文のファイルを省略するか「-」にすると、標準入力を読む。
#   --commit を付けると、作業ツリーではなく、そのコミットまでの変更と比べる。CI で使う。
#   CI の作業ツリーには、テストの実行で生じたファイルが残っていることがあるためである。
# 終了コード: 0 = 問題なし、1 = 足りない節があるか、識別子が一致しない、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

commit=""
if [ "${1:-}" = "--commit" ]; then
  [ -n "${2:-}" ] || mg_die "--commit のあとにコミットを指定する"
  commit="$2"
  shift 2
fi

body_file="${1:-}"
[ -n "$body_file" ] && [ "$body_file" != "-" ] || body_file="/dev/stdin"
body="$(cat "$body_file")" || mg_die "本文を読めない: $body_file"

# 本文のファイルが作業ツリーの中にあると、そのファイル自体が変更として数えられる。
# 本文は自分の内容から決まる識別子を含むことになり、どう書いても一致しない。
# 手元の状態の置き場と、git が無視するパスは、変更に数えないので置いてよい。
if [ -z "$commit" ] && [ "$body_file" != "/dev/stdin" ]; then
  case "$body_file" in
    /*) body_path="$body_file" ;;
    *) body_path="$PWD/$body_file" ;;
  esac
  if body_rel="$(mg_relpath "$body_path")"; then
    case "$body_rel" in
      "$MG_STATE_DIR"/*) ;;
      *)
        git -C "$MG_ROOT" check-ignore -q -- "$body_rel" ||
          mg_die "本文のファイルは、リポジトリの外に置く。中に置くと、そのファイルも変更として数えられ、識別子が一致しない: $body_rel"
        ;;
    esac
  fi
fi

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

# ---- 検証の結果が、いまの変更に対するものか

if [ -n "$commit" ]; then
  git -C "$MG_ROOT" rev-parse --verify --quiet "$commit^{commit}" >/dev/null ||
    mg_die "コミット $commit が見つからない"
  merge_base="$(mg_merge_base "${2:-}" "$commit")" || exit 2
  after="$commit"
else
  merge_base="$(mg_merge_base "${2:-}")" || exit 2
  after="$(mg_worktree_tree)" || mg_die "作業ツリーの内容を読めない"
fi
change_id="$(mg_change_id "$merge_base" "$after")" || mg_die "変更の識別子を計算できない"
marker="$(mg_change_marker "$change_id")"

# 本文をパイプで渡さない。grep -q は一致した時点で読むのをやめるので、長い本文では書き込む側が
# 中断され、pipefail によって、一致したのに失敗として扱われる。
if ! grep -qE -- "$MG_CHANGE_MARKER_PATTERN" <<<"$body"; then
  echo "PR の本文に、検証した変更の識別子がない。本文の最後に次の行を足す: $marker"
  missing=$((missing + 1))
elif ! grep -qF -- "$marker" <<<"$body"; then
  echo "PR の本文の識別子が、いまの変更と一致しない。本文の検証の結果は、別の変更に対するものである"
  echo "足した変更について検査と検証をやり直し、本文を書き直してから、識別子を次の行に置き換える: $marker"
  if [ -z "$commit" ]; then
    echo "識別子は、コミット前の変更と、git に追加していないファイルも含めて計算している"
  else
    echo "PR に入れないファイルが手元の作業ツリーに残っていると、手元で計算した識別子はこの値にならない"
  fi
  missing=$((missing + 1))
fi

[ "$missing" -eq 0 ]
