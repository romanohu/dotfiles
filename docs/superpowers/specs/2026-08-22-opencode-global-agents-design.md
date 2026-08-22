# OpenCode グローバル AGENTS.md 設計

## 目的

OpenCode が全プロジェクトで共通ルールを読み込めるよう、リポジトリ管理下の
`.config/opencode/AGENTS.md` を追加する。内容は既存の `.codex/AGENTS.md` と同じ
最小変更ルールに揃える。

## 採用方針

`.config/opencode/AGENTS.md` は独立した追跡ファイルとして保持する。mise の
`[dotfiles]` 設定で `~/.config/opencode/AGENTS.md` にリンクし、既存の OpenCode
設定と同じ bootstrap 経路で配布する。既存ファイルや別ツールの指示ファイルを
参照する追加のリンク機構は作らない。

## 配布と安全性

- mise の対象に `~/.config/opencode/AGENTS.md` を追加する。
- `install.sh` の managed-target preflight に同じ target/source を追加する。
- 既存の通常ファイル、ディレクトリ、無関係な symlink、symlink ancestor は従来どおり
  拒否し、無断上書きしない。
- 管理対象数は 12 から 13 になる。

## テストと文書

- `AGENTS.md` の内容が既存の共通ルールと一致することを検証する。
- mise mapping と installer preflight の対象に含まれることを検証する。
- README に OpenCode のグローバルルールの配置と管理対象であることを記載する。
- `.codex/AGENTS.md`、`.claude/CLAUDE.md`、OpenCode の permission/plugin 設定、
  WezTerm 設定は変更しない。

## 完了条件

- `~/.config/opencode/AGENTS.md` が mise bootstrap で作成される。
- OpenCode がそのファイルをグローバルルールとして利用できる。
- 既存設定を変更せず、設定・installer・全テストが成功する。
