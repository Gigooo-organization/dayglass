# dayglass

Apple Silicon Mac 向けのローカル工数素材・集計ツールです。前面アプリや AI セッションなどの観測値を素材として保存し、ルールベースの推定と人間の確認を分けて管理します。

## Privacy

ローカルに記録するもの:

- 前面アプリ、ウィンドウタイトル、許可ホストの URL パス、入力アイドル・一時停止
- Claude Code / Codex のセッション・ターン境界とトークン集計値
- `Gigooo-organization/` 配下の GitHub 活動種別・日時・PR 番号

記録しないもの:

- 打鍵、クリック、選択テキスト、AX ツリー、スクリーンショット
- OTLP のプロンプト本文、応答本文、ツール引数・実行結果、URL の query / fragment
- 許可されていないホストの URL パス、コミットメッセージ、PR レビュー本文

生ログは `~/Library/Application Support/dayglass/otlp/YYYY-MM-DD/` に留まります。dayglass 自身が外部へ送信するのは、`gh` 経由の GitHub 読み取りだけです。管理部への提出は `report --freeze` の生成物を人間が確認して手動で行います。

`evidence` はローカルのトランスクリプトから、伏字・文字数上限・合成入力除外を適用した作業抜粋を作ります。Claude Code / Codex の skill で利用する場合、その `report`、質問、伏字済み evidence はエージェントのモデル API に入力され得ます。生ログとトランスクリプト全文は skill に渡しません。

## Install

```sh
brew trust --formula gigooo-organization/dayglass/dayglass
brew install gigooo-organization/dayglass/dayglass
dayglass setup
```

ソースビルドの formula で、`gh` を依存します。`dayglass setup` は既存設定を JSON として読み、Claude Code / Codex の hooks と OTel 設定を必要な分だけ追記し、source ID、`projects.toml`、skill、launchd plist を作成します。既存の設定形式が壊れている場合は上書きせず停止します。

daemon の利用には System Settings の Accessibility 許可が必要です。個人ビルドは `~/.local/libexec/dayglass` の固定パスへ置くため、更新時は Accessibility 許可の再確認が必要です。Keychain Access で同じ名前の自己署名 Code Signing identity を作り、固定パスのバイナリを毎回同じ identity で署名すると再許可の負担を抑えられます。

## Commands

```sh
dayglass daemon
dayglass serve
dayglass hook claude < hook-payload.json
dayglass hook codex < hook-payload.json
dayglass sync github
dayglass report --month 2026-09 --format csv|json|md|otlp-metrics
dayglass report --questions --month 2026-09
dayglass note --question ID --project CODE --category coding
dayglass note --day 2026-09-14 --summary "確認済みの作業内容"
dayglass report --freeze --month 2026-09 --format csv
dayglass evidence --day 2026-09-14
dayglass pause 1h
dayglass reap --days 90
```

`serve` は `127.0.0.1:4318` の JSON OTLP HTTP だけを受け、1 リクエスト 4 MiB を上限に、許可リストにあるレコードと属性だけを日次 JSONL へ書きます。`report` は実行直前に GitHub 同期を試み、認証やネットワークに失敗してもローカル集計は続けます。

## Data and output

保存形式は OTLP/JSON Lines です。提出表は日・プロジェクト・区分、AI 利用、コミット・PR・レビュー数を含みます。コミット数や変更行数は操作で増減できるため、個人評価ではなくチームの傾向把握用の参考値として扱います。

管理部の正式様式が未定のため、初期の CSV 列は `templates/` に置いています。設計判断と制約は [`docs/design.md`](docs/design.md)、実装順序は [`plan.md`](plan.md) を参照してください。

## Development

```sh
swift test
swift build -c release
```

GitHub Actions は macOS 上でテスト・release build を実行し、`v*` tag で Apple Silicon バイナリと checksums を GitHub Release に添付します。
