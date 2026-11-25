#!/bin/bash
# 検査スクリプトと hook が共有する関数。対象リポジトリの検査の設定を読む。
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
# このファイルの中では使わず、読み込む側のスクリプトが使うので、未使用の警告の対象から外す。
# shellcheck disable=SC2034
MG_SPEC_PATH="$MG_STATE_DIR/spec.md"

# 現在のブランチ名を出力する。ブランチの上にいないときは空になる。
mg_current_branch() {
  git -C "$MG_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null
}

# hook が実行をまたいで持つ状態の置き場を出力する。作業ツリーの外に置くのは、
# 状態を書くたびに作業ツリーの内容が変わったと判定されるのを避けるためである。
mg_hook_state_dir() {
  printf '%s/merge-gate\n' "$(git -C "$MG_ROOT" rev-parse --absolute-git-dir)"
}

# 承認の記録が、現在のブランチで取られたものなら 0。
# 記録は、それを取ったブランチの作業にだけ意味がある。マージ後に別のブランチで次の作業を始めたとき、
# 前の作業の記録で編集の確認が出たり終了を止められたりしないよう、別のブランチの記録は無いものとして扱う。
# 削除ではなく無視にしているのは、一時的に別のブランチを見に行っただけで承認を失わないためである。
mg_lock_is_current() {
  local lock="$MG_ROOT/$MG_STATE_DIR/locked" stamp="$MG_ROOT/$MG_STATE_DIR/branch"
  [ -f "$lock" ] || return 1
  [ -f "$stamp" ] || return 1
  [ "$(cat "$stamp")" = "$(mg_current_branch)" ]
}

# 現在のブランチで有効な承認の記録から、承認済みのパスを 1 行ずつ出力する。有効な記録がなければ何も出力しない。
mg_locked_paths() {
  mg_lock_is_current || return 0
  cut -f2 "$MG_ROOT/$MG_STATE_DIR/locked"
}

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

# mg_section_has_content <見出しに含まれる語>: 節があり、空白、HTML コメント、折りたたみのタグ以外の行を含めば 0。
# PR テンプレートの説明用コメントだけが残った節を、書かれたものと数えないため。
# 折りたたみのタグを除くのは、PR の本文では仕様の全文を <details> で囲むからである。
# 閉じタグは最後の節の本文に入るので、中身として数えると、空の節が書かれたものとして通る。
mg_section_has_content() {
  mg_section_body "$1" |
    grep -v -E '^[[:space:]]*$' |
    grep -v -E '^[[:space:]]*<!--.*-->[[:space:]]*$' |
    grep -v -E '^[[:space:]]*</?details[^>]*>[[:space:]]*$' |
    grep -v -E '^[[:space:]]*<summary>.*</summary>[[:space:]]*$' |
    grep -q .
}

mg_die() {
  echo "merge-gate: $*" >&2
  exit 2
}

# worktree の間で共有される git のディレクトリを、実パスで出力する。
mg_git_common_dir() {
  (cd "$MG_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
}

# リポジトリにコミットしない設定の置き場を出力する。
# git のディレクトリに置くのは、対象リポジトリにファイルを足さずに済ませるためである。
# worktree の間で共有されるディレクトリを選ぶのは、worktree を作るたびに設定を作り直さずに済ませるためである。
mg_local_config_path() {
  printf '%s/merge-gate/config.json\n' "$(mg_git_common_dir)"
}

# 対象リポジトリのルートを MG_ROOT に、使う設定のパスを MG_CONFIG に入れる。git リポジトリの外では 1 を返す。
# リポジトリに設定がコミットされていれば、それだけを使う。チームで揃えた設定を、手元の設定で弱められないようにするためである。
mg_find_root() {
  MG_ROOT="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  MG_CONFIG="$MG_ROOT/$MG_CONFIG_NAME"
  [ -f "$MG_CONFIG" ] || MG_CONFIG="$(mg_local_config_path)"
}

mg_has_config() {
  [ -f "$MG_CONFIG" ]
}

mg_require_config() {
  mg_has_config || mg_die "検査の設定がない。config.sh set で保存するか、リポジトリに $MG_CONFIG_NAME を置く"
}

# 手元だけの状態の置き場を、対象リポジトリの .gitignore を変えずに git の管理から外す。
# info/exclude は .gitignore と同じ働きをするが、コミットされない。
# 書き込めない環境でも呼び出し元の処理は止めない。その場合は状態のファイルが未追跡の変更として見えるだけである。
mg_ensure_state_ignored() {
  local exclude
  exclude="$(mg_git_common_dir)/info/exclude" || return 0
  grep -qxF -- "$MG_STATE_DIR/" "$exclude" 2>/dev/null && return 0
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  # 既存の最後の行が改行で終わっていないと、追記した行がその行につながる。
  if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude" 2>/dev/null)" ]; then
    printf '\n' >>"$exclude" 2>/dev/null || return 0
  fi
  printf '%s/\n' "$MG_STATE_DIR" >>"$exclude" 2>/dev/null || return 0
}

# テストが変更を検出できるかの確認に使うコマンドを、1 行ずつ出力する。確認が無効にされていれば 1 を返す。
# checks.red が配列ならそのコマンドを、なければ checks.verify のコマンドを使う。
# 検査が重いリポジトリでは、単体テストだけのように軽いコマンドを checks.red に指定できる。
mg_red_commands() {
  case "$(jq -r '.checks.red | type' "$MG_CONFIG")" in
    boolean)
      [ "$(mg_config '.checks.red')" = "true" ] || return 1
      mg_config '.checks.verify[]?'
      ;;
    array) mg_config '.checks.red[]?' ;;
    *) mg_config '.checks.verify[]?' ;;
  esac
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

# 絶対パスを、symlink を解決した実パスに直す。
# これから作るファイルは親ディレクトリごと存在しないことがあるため、存在する祖先までさかのぼって解決する。
# 存在しないことを理由に判定を諦めると、新規作成の形で保護対象のパスに書き込めてしまう。
mg_physical_path() {
  local dir rest physical
  dir="$(dirname "$1")"
  rest="$(basename "$1")"
  while [ ! -d "$dir" ]; do
    rest="$(basename "$dir")/$rest"
    dir="$(dirname "$dir")"
  done
  physical="$(cd "$dir" && pwd -P)" || return 1
  printf '%s/%s\n' "${physical%/}" "$rest"
}

# 絶対パスを、リポジトリのルートからの相対パスに直す。リポジトリの外なら 1 を返す。
# git が返すルートは symlink を解決した実パスなので、渡されたパスも実パスに揃えてから比べる。
mg_relpath() {
  local physical
  physical="$(mg_physical_path "$1")" || return 1
  case "$physical" in
    "$MG_ROOT"/*) printf '%s\n' "${physical#"$MG_ROOT"/}" ;;
    *) return 1 ;;
  esac
}

# mg_implementation_changes <比較の起点>: 実装に当たる変更を「状態<TAB>パス」で出力する。
# テストが検出すべき変更を数えるために使う。テストは変更を検出する側なので含めない。
# 依存の定義とゲートの設定は、検査の実行環境そのものなので含めない。仕様を要しないパスも含めない。
mg_implementation_changes() {
  local status path tab no_spec_patterns
  tab="$(printf '\t')"
  no_spec_patterns="$(mg_config '.paths.no_spec[]?')"
  mg_name_status "$1" | while IFS="$tab" read -r status path; do
    [ -n "$path" ] || continue
    mg_match "$path" tests && continue
    mg_match "$path" dependencies && continue
    mg_is_gate_path "$path" && continue
    [ -n "$no_spec_patterns" ] && mg_match_patterns "$path" "$no_spec_patterns" && continue
    printf '%s\t%s\n' "$status" "$path"
  done
}

# mg_name_status <比較元>: 変更を「状態<TAB>パス」で出力する。
# core.quotePath の既定は true で、非 ASCII のパスは引用符と八進エスケープになる。
# その文字列は paths の glob と一致しないので、既存テストやゲートの変更を検知できない。
mg_name_status() {
  git -C "$MG_ROOT" -c core.quotepath=off diff --name-status --no-renames "$1" --
}

# 未追跡のパスを 1 行ずつ出力する。引用を切る理由は mg_name_status と同じ。
mg_untracked_paths() {
  git -C "$MG_ROOT" -c core.quotepath=off ls-files -o --exclude-standard
}

# mg_added_lines <比較の起点>: このブランチで追加された行を「パス<TAB>行番号<TAB>内容」の形で出力する。
# まだ git に追加していないファイルは、全行を追加された行として扱う。
# 変更後のファイル全体ではなく追加された行だけを見るのは、以前からある記述を今回の変更の責任にしないためである。
mg_added_lines() {
  {
    # 追加行のパスも引用させない。理由は mg_name_status と同じ。
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
    mg_untracked_paths | while IFS= read -r path; do
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
