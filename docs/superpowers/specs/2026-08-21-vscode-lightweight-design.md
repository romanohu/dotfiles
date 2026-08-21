# VS Code 軽量化設計

## 背景

現在の dotfiles には VS Code 設定がなく、実機のユーザー設定には個人用の
Git、Python、Copilot、Remote-SSH、Markdown 設定が混在している。設定全体を
dotfiles に取り込むと、ホスト名や接続先などの個人状態を別マシンへ複製する
ため、軽量化に必要な設定だけを新規に管理する。

実機では VS Code のユーザーデータが約 3.4 GB、拡張機能が約 2.5 GB あり、
拡張機能 Profile は未作成だった。したがって、まず拡張機能の常時有効数を
Profile で整理し、ファイル監視・検索除外と UI の軽量化を設定する。

## 目標

- 巨大な生成ディレクトリを VS Code のファイル監視と検索から除外する。
- minimap、breadcrumbs、CodeLens など常時表示される UI の負荷とノイズを減らす。
- 既存の個人設定、Remote-SSH の接続先、拡張機能、拡張機能キャッシュを
  dotfiles の管理対象にしない。
- macOS と Linux の公式 VS Code ユーザー設定パスに対応する。
- VS Code が未インストールのマシンではインストールを失敗させない。

## 非目標

- 拡張機能の自動インストール、アンインストール、更新。
- VS Code Profile の自動作成や Profile 内の拡張機能一覧の固定。
- Remote-SSH のホスト設定や接続スクリプトの管理。
- VS Code のキャッシュ削除、ユーザーデータ削除、既存設定の自動マージ。
- `terminal.integrated.gpuAcceleration` の強制変更。

## 採用する構成

### 軽量化設定ファイル

新規 `.config/vscode/settings.json` を strict JSON として追跡する。内容は次の
設定だけに限定する。

- `files.watcherExclude`: `.git/objects`、`node_modules`、`target`、`.venv`、
  `.cache`、`dist`、`build`
- `search.exclude`: 同じ生成・依存ディレクトリ
- `editor.minimap.enabled = false`
- `breadcrumbs.enabled = false`
- `editor.codeLens = false`
- `workbench.startupEditor = "none"`

プロジェクト固有の生成ディレクトリは各リポジトリの `.vscode/settings.json`
で追加する。グローバル設定でソースディレクトリを隠さない。

### 適用方法

mise の `[dotfiles]` は macOS と Linux のユーザー設定パスを同時に表現できない
ため、VS Code 設定だけ install.sh の小さな platform-aware helper でリンクする。

- macOS: `$TARGET_HOME/Library/Application Support/Code/User/settings.json`
- Linux: `$TARGET_HOME/.config/Code/User/settings.json`

対象の `User` ディレクトリが存在しない場合は `VS Code settings: skipped` と
して成功扱いにする。VS Code 未導入のマシンに不要なディレクトリを作らない。

対象ファイルが存在する場合は、dotfiles の他の管理対象と同じ安全規則を使う。
存在しないか、物理リポジトリの設定ファイルを指す正しい symlink の場合だけ
許可し、それ以外の通常ファイル・ディレクトリ・別 symlink は上書きせずに
bootstrap を停止する。既存の settings.json の自動マージや削除はしない。

### 拡張機能 Profile

Profile は dotfiles で自動作成しない。VS Code の Profile 機能を使って、普段用、
Python/Jupyter 用、C/C++/Rust 用などを手動で分ける。dotfiles は Profile 内の
拡張機能を決めず、ユーザーが必要なワークロードだけ有効にする。

## 安全性と互換性

- 対応 OS は既存 installer と同じ macOS／Linux。
- Windows 対応は追加しない。
- 設定ファイルに個人ホスト名、認証情報、拡張機能 ID は書かない。
- `git.autofetch`、Copilot、Python、Remote-SSH など現在の個人設定は変更しない。
- `settings.json` の衝突時には既存内容を保存したまま停止し、手動退避後に再実行する。
- install.sh の再実行は、正しい symlink がある場合に冪等に成功する。

## 検証

オフライン・ホスト非依存の既存テストに次を追加する。

- 設定ファイルが strict JSON で、許可したキーと除外対象だけを含むこと。
- Remote-SSH のホスト名、拡張機能 ID、認証情報らしき設定を含まないこと。
- macOS／Linux の設定ターゲット計算が正しいこと。
- VS Code User ディレクトリがない場合は skip すること。
- 既存の通常ファイル、別 symlink、正しい symlink、再実行を隔離 HOME で検証すること。
- Bash／Zsh 構文、既存 `bash tests/run.sh`、JSON 検証を通すこと。

実機の拡張機能 Profile 作成とキャッシュ削除は、この変更の外でユーザーが
VS Code の UI から行う。
