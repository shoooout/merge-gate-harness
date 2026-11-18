#!/bin/bash
# Stop hook。エージェントが作業を終えようとした時点で、承認済みファイルの照合と検査コマンドを実行し、
# 失敗していれば終了させずに直させる。CI と同じ verify.sh を呼ぶので、ここを通れば CI の同じ検査も通る。
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
stop_hook_active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false')"

mg_find_root "${cwd:-.}" || exit 0
mg_has_config || exit 0

state_dir="$(git -C "$MG_ROOT" rev-parse --absolute-git-dir)/merge-gate"
mkdir -p "$state_dir"

# 作業ツリーの内容を 1 つの値にまとめる。同じ内容に対して検査を繰り返さないための目印に使う。
# 未追跡ファイルは status に名前しか出ないので、中身のハッシュも含める。
fingerprint() {
  {
    git -C "$MG_ROOT" rev-parse HEAD 2>/dev/null
    git -C "$MG_ROOT" status --porcelain
    git -C "$MG_ROOT" diff HEAD 2>/dev/null
    (cd "$MG_ROOT" && git ls-files -o --exclude-standard -z | xargs -0 git hash-object -- 2>/dev/null)
  } | git hash-object --stdin
}

# 分岐元から何も変えていなければ検査しない。質問に答えただけのやり取りで毎回テストを走らせないため。
merge_base="$(mg_merge_base 2>/dev/null)" || merge_base="HEAD"
if git -C "$MG_ROOT" diff --quiet "$merge_base" -- 2>/dev/null &&
  [ -z "$(git -C "$MG_ROOT" ls-files -o --exclude-standard)" ]; then
  exit 0
fi

current="$(fingerprint)"

if [ -f "$state_dir/last-pass" ] && [ "$(cat "$state_dir/last-pass")" = "$current" ]; then
  exit 0
fi

# 前回止めたときから何も変わっていないなら、エージェントは直せずに止まろうとしている。
# 同じ理由で止め続けても進まないので終了を許し、判定は CI と人間に委ねる。
if [ "$stop_hook_active" = "true" ] &&
  [ -f "$state_dir/last-block" ] && [ "$(cat "$state_dir/last-block")" = "$current" ]; then
  exit 0
fi

report=""

if ! lock_output="$(cd "$MG_ROOT" && bash "$SCRIPTS_DIR/lock.sh" verify 2>&1)"; then
  report="$report$lock_output
承認済みの内容に戻すか、変更が必要な理由を利用者に説明して承認を得ること。
"
fi

# 承認済みの仕様がある作業では、実装後も仕様との対応が保たれているかを確かめる。
# 承認の時点では通っていても、実装中に受け入れ条件のテストを消したり、
# 承認時に示していない既存テストを変更したりすると、ここで落ちる。
if [ -f "$MG_ROOT/$MG_STATE_DIR/locked" ] &&
  cut -f2 "$MG_ROOT/$MG_STATE_DIR/locked" | grep -qxF -- "$MG_SPEC_PATH" &&
  [ -f "$MG_ROOT/$MG_SPEC_PATH" ]; then
  if ! spec_output="$(cd "$MG_ROOT" && bash "$SCRIPTS_DIR/checks/spec.sh" "$MG_SPEC_PATH" 2>&1)"; then
    report="$report$spec_output
"
  fi
fi

# 秘密の値は、コミットされる前に止める。コミットされたあとでは、値を無効にして発行し直すしかなくなる。
secrets_output="$(cd "$MG_ROOT" && bash "$SCRIPTS_DIR/checks/secrets.sh" 2>&1)"
if [ $? -eq 1 ]; then
  report="$report$secrets_output
"
fi

verify_output="$(cd "$MG_ROOT" && bash "$SCRIPTS_DIR/checks/verify.sh" 2>&1)"
verify_status=$?
if [ "$verify_status" -eq 2 ]; then
  # 設定の不備はエージェントには直せない。止め続けず、利用者に見える形で知らせる。
  printf 'merge-gate: 検査を実行できなかった。\n%s\n' "$verify_output" >&2
  exit 1
elif [ "$verify_status" -ne 0 ]; then
  report="$report$verify_output
"
fi

if [ -n "$report" ]; then
  printf '%s' "$current" >"$state_dir/last-block"
  printf 'merge-gate: 検査が通っていないので作業を終了できない。テストや検査を緩めず、原因を直すこと。\n%s' "$report" >&2
  exit 2
fi

printf '%s' "$current" >"$state_dir/last-pass"
exit 0
