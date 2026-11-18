#!/bin/bash
# 人間が承認した仕様と受け入れテストを記録し、承認後に書き換えられていないかを確かめる。
# 実装に合わせてテストや仕様のほうを直す、という逆転を検知するための仕組みである。
#
# 記録先は対象リポジトリの .merge-gate/ で、手元だけの状態なのでコミットしない。
# 対象リポジトリの .gitignore に .merge-gate/ を入れておく。
#
# 記録は、それを取ったブランチでだけ有効になる。別のブランチにいる間は無いものとして扱うので、
# マージ後に新しいブランチで次の作業を始めるときに、前の記録を手で消す必要はない。
#
# 使い方:
#   lock.sh add <ファイル>...  承認された内容として記録する。記録済みのファイルは上書きする。
#                              別のブランチの記録が残っていれば、捨ててから記録する
#   lock.sh verify             記録した内容から変わったファイルを表示する
#   lock.sh list               記録しているファイルを表示する
#   lock.sh clear              記録をすべて消す。同じブランチで別の依頼を始めるときに使う
# 終了コード: 0 = 成功、1 = verify で変更が見つかった、2 = 使い方や環境の問題
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
LOCK_FILE="$MG_ROOT/$MG_STATE_DIR/locked"
BRANCH_FILE="$MG_ROOT/$MG_STATE_DIR/branch"

# 記録は「<git のオブジェクト ID><タブ><ルートからの相対パス>」の行で持つ。
# shasum と sha256sum の違いを避けるため、どの環境にもある git hash-object を使う。
hash_of() {
  git -C "$MG_ROOT" hash-object -- "$1" 2>/dev/null
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  add)
    [ $# -gt 0 ] || mg_die "記録するファイルを指定する"
    rels=""
    has_spec=0
    for file in "$@"; do
      [ -f "$file" ] || mg_die "ファイルがない: $file"
      case "$file" in
        /*) abs="$file" ;;
        *) abs="$PWD/$file" ;;
      esac
      rel="$(mg_relpath "$abs")" || mg_die "リポジトリの外のファイルは記録できない: $file"
      [ "$rel" = "$MG_SPEC_PATH" ] && has_spec=1
      rels="$rels$rel
"
    done

    # 形の整っていない仕様は、承認済みとして記録させない。記録を先に済ませると、
    # 不備のある仕様のまま実装が始まり、あとから直すたびに承認の取り直しになる。
    if [ "$has_spec" -eq 1 ]; then
      if ! spec_output="$(bash "$(dirname "${BASH_SOURCE[0]}")/checks/spec.sh" "$MG_ROOT/$MG_SPEC_PATH" 2>&1)"; then
        printf '%s\n' "$spec_output" >&2
        mg_die "仕様の検査が通らないので、承認済みとして記録できない"
      fi
    fi

    mkdir -p "$MG_ROOT/$MG_STATE_DIR"
    if ! mg_lock_is_current; then
      : >"$LOCK_FILE"
      mg_current_branch >"$BRANCH_FILE"
    fi
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      hash="$(hash_of "$rel")" || mg_die "ハッシュを計算できない: $rel"
      awk -F '\t' -v path="$rel" '$2 != path' "$LOCK_FILE" >"$LOCK_FILE.tmp"
      printf '%s\t%s\n' "$hash" "$rel" >>"$LOCK_FILE.tmp"
      mv "$LOCK_FILE.tmp" "$LOCK_FILE"
      echo "記録: $rel"
    done <<EOF
$rels
EOF
    ;;
  verify)
    mg_lock_is_current || exit 0
    changed=0
    while IFS="$(printf '\t')" read -r hash rel; do
      [ -n "$rel" ] || continue
      if [ ! -f "$MG_ROOT/$rel" ]; then
        echo "承認済みのファイルが削除されている: $rel"
        changed=$((changed + 1))
      elif [ "$(hash_of "$rel")" != "$hash" ]; then
        echo "承認済みのファイルが承認後に変更されている: $rel"
        changed=$((changed + 1))
      fi
    done <"$LOCK_FILE"
    [ "$changed" -eq 0 ]
    ;;
  list)
    mg_locked_paths
    ;;
  clear)
    rm -f "$LOCK_FILE" "$BRANCH_FILE"
    ;;
  *)
    mg_die "使い方: lock.sh add <ファイル>... | verify | list | clear"
    ;;
esac
