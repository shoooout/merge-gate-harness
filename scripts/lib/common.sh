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

# 作業中の仕様を置く場所。承認の記録と同じく、手元だけの状態としてコミットしない。
MG_SPEC_PATH="$MG_STATE_DIR/spec.md"

# mg_section_body <見出しに含まれる語>: 標準入力の Markdown から、その見出しの節の本文を出力する。
# 見出しの階層は問わない。仕様の文書では「## 要件」、PR の本文では「### 要件」のように階層が変わるため。
# コードブロックの中の「# 」で始まる行は、シェルのコメントなどであって見出しではないので、節の区切りにしない。
mg_section_body() {
  awk -v section="$1" '
    /^[ \t]*(```|~~~)/ {
      fenced = !fenced
      if (inside) print
      next
    }
    !fenced && /^#+[ \t]/ {
      inside = (index($0, section) > 0)
      next
    }
    inside { print }
  '
}

# mg_section_has_content <見出しに含まれる語>: 節があり、空白と HTML コメント以外の行を含めば 0。
# PR テンプレートの説明用コメントだけが残った節を、書かれたものと数えないため。
mg_section_has_content() {
  mg_section_body "$1" |
    grep -v -E '^[[:space:]]*$' |
    grep -v -E '^[[:space:]]*<!--.*-->[[:space:]]*$' |
    grep -q .
}

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

# mg_added_lines <比較の起点>: このブランチで追加された行を「パス<TAB>行番号<TAB>内容」の形で出力する。
# まだ git に追加していないファイルは、全行を追加された行として扱う。
# 変更後のファイル全体ではなく追加された行だけを見るのは、以前からある記述を今回の変更の責任にしないためである。
mg_added_lines() {
  {
    git -C "$MG_ROOT" -c core.quotepath=off diff -U0 --no-renames --no-color "$1" -- | awk '
      # ファイルごとのヘッダーの中でだけ「+++ 」をパスとして読む。
      # 本文の追加行がたまたま「++ 」で始まっていても、パスと取り違えないようにする。
      /^diff --git / { header = 1; next }
      header && /^\+\+\+ / {
        path = substr($0, 5)
        sub(/^b\//, "", path)
        sub(/\t$/, "", path)
        next
      }
      /^@@ / {
        header = 0
        split($3, range, ",")
        line = substr(range[1], 2) + 0
        next
      }
      !header && /^\+/ {
        printf "%s\t%d\t%s\n", path, line, substr($0, 2)
        line++
      }
    '
    git -C "$MG_ROOT" -c core.quotepath=off ls-files -o --exclude-standard | while IFS= read -r path; do
      # バイナリは行として読めないので対象にしない
      grep -Iq . "$MG_ROOT/$path" 2>/dev/null || continue
      awk -v path="$path" '{ printf "%s\t%d\t%s\n", path, NR, $0 }' "$MG_ROOT/$path"
    done
  } | awk -F '\t' -v state="$MG_STATE_DIR/" 'index($1, state) != 1'
}

# mg_grep_added <mg_added_lines の出力> <正規表現>: 内容が一致した行を「パス:行番号」で出力する。一致がなければ 1。
# 一致した内容そのものは出力しない。秘密の値の検出にも使うので、検出結果に値を載せないためである。
mg_grep_added() {
  local numbers
  numbers="$(printf '%s\n' "$1" | cut -f3- | grep -nE -- "$2" | cut -d: -f1 | tr '\n' ',')"
  [ -n "$numbers" ] || return 1
  printf '%s\n' "$1" | awk -F '\t' -v numbers="$numbers" '
    BEGIN {
      count = split(numbers, list, ",")
      for (i = 1; i <= count; i++) wanted[list[i]] = 1
    }
    NR in wanted { print $1 ":" $2 }
  '
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
