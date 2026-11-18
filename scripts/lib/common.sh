#!/bin/bash
# 検査スクリプトと hook が共有する関数。対象リポジトリの .merge-gate.json を読む。
# macOS 標準の bash 3.2 でも動かすので、連想配列や mapfile は使わない。

MG_CONFIG_NAME=".merge-gate.json"
MG_STATE_DIR=".merge-gate"

# 対象リポジトリの設定に書き忘れがあっても、ゲート自体を無効にする変更は必ず人間に回す。
# 設定ファイルで上書きできるようにすると、設定を書き換えるだけでゲートを外せてしまう。
MG_BUILTIN_GATE_PATTERNS=".merge-gate.json
.merge-gate/*
.github/*
.claude/*"

mg_die() {
  echo "merge-gate: $*" >&2
  exit 2
}

# 対象リポジトリのルートを MG_ROOT に入れる。git リポジトリの外では 1 を返す。
mg_find_root() {
  MG_ROOT="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  MG_CONFIG="$MG_ROOT/$MG_CONFIG_NAME"
}

mg_has_config() {
  [ -f "$MG_CONFIG" ]
}

# mg_config <jq フィルタ>: 設定から値を 1 行ずつ取り出す。該当がなければ何も出力しない。
mg_config() {
  jq -r "$1 // empty" "$MG_CONFIG"
}

# mg_match_patterns <パス> <改行区切りの glob>: どれかに一致すれば 0。
# case の glob なので `*` は `/` もまたぐ。`tests/*` は配下のすべての階層に一致する。
mg_match_patterns() {
  local path="$1" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) return 0 ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# mg_match <パス> <paths のキー>: 設定の paths.<キー> のどれかに一致すれば 0。
mg_match() {
  mg_match_patterns "$1" "$(mg_config ".paths.$2[]?")"
}

mg_is_gate_path() {
  mg_match_patterns "$1" "$MG_BUILTIN_GATE_PATTERNS" || mg_match "$1" gate
}

# 絶対パスを、リポジトリのルートからの相対パスに直す。リポジトリの外なら 1 を返す。
# git が返すルートは symlink を解決した実パスなので、渡されたパスも実パスに揃えてから比べる。
# これから作るファイルは親ディレクトリごと存在しないことがあるため、存在する祖先までさかのぼって解決する。
# 存在しないことを理由に判定を諦めると、新規作成の形で保護対象のパスに書き込めてしまう。
mg_relpath() {
  local dir rest physical
  dir="$(dirname "$1")"
  rest="$(basename "$1")"
  while [ ! -d "$dir" ]; do
    rest="$(basename "$dir")/$rest"
    dir="$(dirname "$dir")"
  done
  physical="$(cd "$dir" && pwd -P)" || return 1
  case "$physical/$rest" in
    "$MG_ROOT"/*) printf '%s\n' "${physical#"$MG_ROOT"}/$rest" | sed 's|^/||' ;;
    *) return 1 ;;
  esac
}

# 比較の起点にするコミットを出力する。設定の base との merge-base を使うので、
# base ブランチ側だけが進んでいても、このブランチの変更だけが差分になる。
mg_merge_base() {
  local base="${1:-}"
  [ -n "$base" ] || base="$(mg_config '.base')"
  [ -n "$base" ] || base="origin/main"
  git -C "$MG_ROOT" merge-base "$base" HEAD 2>/dev/null ||
    mg_die "比較元 $base との merge-base が見つからない。fetch されているか、.merge-gate.json の base を確認する"
}
