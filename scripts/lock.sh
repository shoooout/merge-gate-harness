#!/bin/bash
# 人間が承認した仕様と受け入れテストを記録し、承認後に書き換えられていないかを確かめる。
# 実装に合わせてテストや仕様のほうを直す、という逆転を検知するための仕組みである。
#
# 記録先は対象リポジトリの .merge-gate/locked で、作業中のブランチだけに意味がある手元の状態なので
# コミットしない。対象リポジトリの .gitignore に .merge-gate/ を入れておく。
#
# 使い方:
#   lock.sh add <ファイル>...  承認された内容として記録する。記録済みのファイルは上書きする
#   lock.sh verify             記録した内容から変わったファイルを表示する
#   lock.sh list               記録しているファイルを表示する
#   lock.sh clear              記録をすべて消す。マージ後や作業をやり直すときに使う
# 終了コード: 0 = 成功、1 = verify で変更が見つかった、2 = 使い方や環境の問題
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
LOCK_FILE="$MG_ROOT/$MG_STATE_DIR/locked"

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
    mkdir -p "$MG_ROOT/$MG_STATE_DIR"
    touch "$LOCK_FILE"
    for file in "$@"; do
      abs="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)/$(basename "$file")"
      [ -f "$abs" ] || mg_die "ファイルがない: $file"
      root_real="$(cd "$MG_ROOT" && pwd -P)"
      case "$abs" in
        "$root_real"/*) rel="${abs#"$root_real"/}" ;;
        *) mg_die "リポジトリの外のファイルは記録できない: $file" ;;
      esac
      hash="$(hash_of "$rel")" || mg_die "ハッシュを計算できない: $file"
      awk -F '\t' -v path="$rel" '$2 != path' "$LOCK_FILE" >"$LOCK_FILE.tmp"
      printf '%s\t%s\n' "$hash" "$rel" >>"$LOCK_FILE.tmp"
      mv "$LOCK_FILE.tmp" "$LOCK_FILE"
      echo "記録: $rel"
    done
    ;;
  verify)
    [ -f "$LOCK_FILE" ] || exit 0
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
    [ -f "$LOCK_FILE" ] || exit 0
    cut -f2 "$LOCK_FILE"
    ;;
  clear)
    rm -f "$LOCK_FILE"
    ;;
  *)
    mg_die "使い方: lock.sh add <ファイル>... | verify | list | clear"
    ;;
esac
