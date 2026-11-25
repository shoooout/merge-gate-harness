#!/bin/bash
# SessionStart hook。検査の設定があるリポジトリで、手元の状態の置き場を git の管理から外し、
# 実装の依頼では仕様の承認から始めることをエージェントに伝える。
#
# 設定はリポジトリの外にも置けるので、エージェントはファイルを見ただけでは、このリポジトリで
# ハーネスが有効かどうかを判断できない。そのため、有効であることをここで伝える。
# 伝えるだけで強制はしない。守らせたいことは、編集前の確認と終了時の検査で守る。
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# jq がないと、ほかの hook は入力を読めず、何も検査しないまま成功として終わる。
# 検査が働いていると利用者が思い込んだまま作業が進むのを避けるため、ここで知らせる。
if ! command -v jq >/dev/null 2>&1; then
  mg_find_root "${CLAUDE_PROJECT_DIR:-.}" || exit 0
  mg_has_config || exit 0
  echo "merge-gate: jq が見つからないので、編集前の確認と終了時の検査が働いていない。このことを利用者に知らせること。"
  exit 0
fi

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"

mg_find_root "${cwd:-.}" || exit 0
mg_has_config || exit 0
mg_ensure_state_ignored

echo "merge-gate: このリポジトリには検査の設定がある。機能の追加・変更・不具合修正の依頼では、実装の前に merge-gate:acceptance-first の手順を使うこと。"
exit 0
