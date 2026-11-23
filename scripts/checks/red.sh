#!/bin/bash
# このブランチの変更を、テストが実際に検出できるかを確かめる。
# テスト以外の変更を分岐元の状態に戻して検査を実行し、失敗することを確かめる。
# 戻しても検査がすべて通るなら、追加したテストは今回の変更を何も検証していないか、テストが追加されていない。
#
# 「テストが通った」は、テストが変更を検出できる場合にだけ根拠になる。受け入れテストを実装前に落とす手順は
# skill にあるが、手順は守られる保証がないので、同じことを結果から確かめる。
#
# 作業ツリーのファイルを一時的に書き換えるので、未コミットの変更がない状態でだけ動く。主に CI で使う。
#
# 使い方: red.sh --in-place [比較元の ref]
# 終了コード: 0 = テストが変更を検出する、または確かめる対象がない
#             3 = 変更を検出するテストがない、2 = 設定や環境の問題
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mg_find_root || mg_die "git リポジトリの中で実行する"
mg_has_config || mg_die "$MG_CONFIG_NAME がない"

# 作業ツリーを書き換えることを、呼び出す側に明示させる。意図せず手元で実行されるのを避けるためである。
[ "${1:-}" = "--in-place" ] || mg_die "作業ツリーを一時的に書き換える。承知のうえで --in-place を付けて実行する"
shift

# checks.red が false なら確かめない。配列ならそのコマンドを、なければ checks.verify のコマンドを使う。
# 検査が重いリポジトリでは、単体テストだけのように軽いコマンドを checks.red に指定できる。
red_type="$(jq -r '.checks.red | type' "$MG_CONFIG")"
case "$red_type" in
  boolean)
    [ "$(mg_config '.checks.red')" = "true" ] || exit 0
    commands="$(mg_config '.checks.verify[]?')"
    ;;
  array) commands="$(mg_config '.checks.red[]?')" ;;
  *) commands="$(mg_config '.checks.verify[]?')" ;;
esac
[ -n "$commands" ] || mg_die "実行する検査がない。$MG_CONFIG_NAME の checks.verify か checks.red を設定する"

if [ -n "$(git -C "$MG_ROOT" status --porcelain)" ]; then
  mg_die "未コミットの変更がある。作業ツリーを書き換えるので、変更のない状態で実行する"
fi

merge_base="$(mg_merge_base "${1:-}")" || exit 2

# 戻す対象は、実装に当たるファイルだけにする。
# テストは今回の変更を検出する側なので残す。依存の定義とゲートの設定は、戻すと検査の実行環境そのものが変わり、
# 変更を検出したのではなく環境が壊れただけの失敗を「検出した」と数えてしまう。
TAB="$(printf '\t')"
no_spec_patterns="$(mg_config '.paths.no_spec[]?')"
targets=""
while IFS="$TAB" read -r status path; do
  [ -n "$path" ] || continue
  mg_match "$path" tests && continue
  mg_match "$path" dependencies && continue
  mg_is_gate_path "$path" && continue
  [ -n "$no_spec_patterns" ] && mg_match_patterns "$path" "$no_spec_patterns" && continue
  targets="$targets$status$TAB$path
"
done <<EOF
$(mg_name_status "$merge_base")
EOF

[ -n "$targets" ] || exit 0

# このブランチで削除したファイルは、戻すと作業ツリーに現れる。検査のあとで消すために覚えておく。
recreated=""
restore() {
  # 開始時に未コミットの変更がないことを確かめているので、インデックスの内容が元の状態である。
  # インデックスから書き戻せば、内容も実行権限も元に戻る。
  git -C "$MG_ROOT" checkout-index -f -a
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f "$MG_ROOT/$path"
  done <<EOF
$recreated
EOF
}
trap restore EXIT

while IFS="$TAB" read -r status path; do
  [ -n "$path" ] || continue
  case "$status" in
    A) rm -f "$MG_ROOT/$path" ;;
    D)
      mkdir -p "$(dirname "$MG_ROOT/$path")"
      git -C "$MG_ROOT" show "$merge_base:$path" >"$MG_ROOT/$path"
      recreated="$recreated$path
"
      ;;
    *) git -C "$MG_ROOT" show "$merge_base:$path" >"$MG_ROOT/$path" ;;
  esac
done <<EOF
$targets
EOF

detected=0
while IFS= read -r command; do
  [ -n "$command" ] || continue
  if ! (cd "$MG_ROOT" && bash -c "$command") >/dev/null 2>&1 </dev/null; then
    detected=1
    break
  fi
done <<EOF
$commands
EOF

if [ "$detected" -eq 0 ]; then
  echo "テスト以外の変更を分岐元の状態に戻しても、検査がすべて通る。この変更を検出するテストがない"
  exit 3
fi
exit 0
