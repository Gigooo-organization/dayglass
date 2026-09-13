# dayglass

Apple Silicon Mac 向けのローカル完結型・工数記録および集計ツールです。フォアグラウンドのアプリケーション操作や AI セッションなどの客観的な観測データを「工数の素材」として収集・保存し、ルールベースによる自動推定と人間による対話的な確認（確定）を明確に分離して管理します。

## Privacy

ローカル環境にのみ記録・保持するもの:

- フォアグラウンドアプリ、ウィンドウタイトル、許可ホストの URL パス、入力アイドル時間、画面ロック・スリープ状態
- Claude Code / Codex のセッションおよびターンの開始・終了境界、トークン集計値
- `Gigooo-organization/` 配下リポジトリの GitHub アクティビティ種別、日時、PR 番号

記録しないもの:

- 打鍵内容、クリック位置、選択テキスト、Accessibility（AX）ツリー、スクリーンショット
- OTLP 経由のプロンプト本文、応答本文、ツール引数・実行結果、URL のクエリパラメータおよびフラグメント
- 許可ホスト以外の URL パス、コミットメッセージ本文、PR レビュー本文

収集された生ログはローカル環境（`~/Library/Application Support/dayglass/otlp/YYYY-MM-DD/`）にのみ保存され、外部サーバへ直接送信されることはありません。dayglass 自体が行う外部通信は、`gh` コマンドを経由した GitHub データの読み取りのみです。管理部への提出は、`report --freeze` により生成された集計ファイルを人間が内容確認した上で、手動で提出します。

`evidence` コマンドは、ローカルのトランスクリプトからマスキング（伏字）、文字数上限、システム合成入力の除外を適用した安全な作業抜粋を生成します。Claude Code や Codex の skill を利用して対話形式で確認を行う場合、生成された `report`、未確定事項の質問、マスキング済み evidence はエージェント経由でモデル API（クラウド）へ入力として渡されます。なお、生ログやトランスクリプトの全文が skill に渡されることはありません。

## Install

```sh
brew trust --formula gigooo-organization/dayglass/dayglass
brew install gigooo-organization/dayglass/dayglass
dayglass setup
```

Homebrew の仕様上、非公式 tap の利用には明示的な信頼設定が必要となるため、あらかじめ `brew trust` で formula を信頼した上でインストールします。ローカルでコンパイルするソースビルド形式の formula であり、依存関係として `gh`（GitHub CLI）が必要です。

`dayglass setup` コマンドを実行すると、既存の設定ファイルを保持しながら Claude Code / Codex 向けの hooks および OTel 設定を自動で追記し、端末固有の source ID、`projects.toml`（プロジェクト定義）、skill、launchd 向け plist ファイルを一括生成します。なお、既存の設定ファイルが破損している場合は、意図しない上書きを防ぐため処理を安全に中断します。

フォアグラウンドアプリの監視（daemon）を利用するには、macOS の「システム設定 > プライバシーとセキュリティ > アクセシビリティ」での実行許可が必要です。Developer ID を用いない個人ビルドではバイナリを `~/.local/libexec/dayglass` の固定パスに配置するため、バイナリ更新のたびにアクセシビリティ権限の再許可が求められます。キーチェーンアクセスで同名の自己署名コード署名証明書（Code Signing identity）を作成し、固定パスのバイナリを毎回同一の identity で署名することで、更新時の再許可の手間を最小限に抑えることができます。

## Update

dayglass を最新バージョンに更新し、常駐デーモン用の固定パスへ新バイナリを反映する手順です。

```sh
brew upgrade gigooo-organization/dayglass/dayglass
dayglass setup
```

Homebrew の仕様上、更新チェック時に tap のメタデータ更新が走る場合がありますが、`brew upgrade` によって実際にアップグレードされるパッケージは dayglass のみです。更新が存在しない場合は何も変更されません。

## Project configuration

`dayglass setup` を実行すると、`~/.config/dayglass/projects.toml` が存在しない場合に設定ファイルの雛形が作成されます。このファイルには、収集した git リポジトリ、作業ディレクトリ、ウィンドウタイトル、URL などを管理部指定のプロジェクトコードへ対応付ける判定ルールを記述します。

```toml
[[project]]
code = "DAYGLASS"
name = "dayglass"
git = ["*github.com/Gigooo-organization/dayglass*", "*/Gigooo-organization/dayglass"]
title = ["dayglass"]
url = ["github.com/Gigooo-organization/dayglass*"]

[[project]]
code = "CUSTOMER-A"
name = "顧客A"
git = ["*github.com/Gigooo-organization/customer-a*", "*/Gigooo-organization/customer-a"]
title = ["customer-a", "顧客A"]
url = ["customer-a.example.com*"]
```

管理対象の案件（プロジェクト）ごとに `[[project]]` ブロックを追加します。各項目の仕様は次のとおりです。

- `code`（必須）: レポートに出力されるプロジェクトコード
- `name`: 設定ファイルを識別・管理するためのプロジェクト名称
- `git`: Git リポジトリの URL または作業ディレクトリのパスに照合するパターン
- `title`: ウィンドウタイトルに照合するパターン
- `url`: ブラウザのドメイン、またはドメインとパスを連結した文字列に照合するパターン

パターンの照合は大文字・小文字を区別せずに行われ、ワイルドカードとして `*`（任意の文字列）が使用可能です。`*` を含まない文字列を指定した場合は部分一致として扱われます。
複数のルールが同一のウィンドウ情報に合致した場合は、ファイル内で**先に記述されたルールが優先**されます。
なお、本設定は `dayglass report` による集計時に動的に評価されます。そのため、設定変更後に daemon を再起動する必要はなく、次回の集計実行時から過去のログに対しても遡及して適用されます。

既定の作業区分判定ルールを拡張・カスタマイズしたい場合は、同ファイル内に `[[category]]` ブロックを追加します。

```toml
[[category]]
category = "review"
domains = ["reviews.example.com"]
paths = ["/diff/"]
bundles = ["com.example.ReviewApp"]
```

- `category`: 対象とする作業区分（`research` / `coding` / `review` / `docs` / `meeting` / `other` のいずれか）を指定
- `domains` / `bundles`: 該当するドメイン名またはアプリケーションの bundle ID（ワイルドカード `*` に対応）
- `paths`: URL パス（部分一致で判定）

同一の `[[category]]` ブロック内では、いずれか 1 つの条件に合致した時点で該当の作業区分として判定されます。なお、既定の判定ルールで十分な場合は `[[category]]` の記述を省略できます。

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

`serve` は `127.0.0.1:4318` にて JSON 形式の OTLP/HTTP リクエストのみを受け付けます。1 リクエストあたり 4 MiB を上限とし、許可リストに定義されたレコードおよび属性のみを抽出して日別の JSON Lines ファイルへ追記します。`report` は集計実行の直前に GitHub からの最新イベント同期（`sync github`）を試みますが、ネットワーク切断や未認証などで同期に失敗した場合でも、手元のローカルログを用いて集計処理を継続します。

## Data and output

データの保存形式には OTLP/JSON Lines を採用しています。提出用の集計レポートには、日別・プロジェクト別・作業区分別の稼働時間、AI 併用時間、コミット数・作成 PR 数・レビューした PR 数などが含まれます。なお、コミット数や変更行数は作業スタイルによって増減し得る指標であるため、個人の人事評価ではなく、チーム全体の活動傾向を把握するための参考値として扱います。

管理部が指定する正式な提出様式は確定していないため、初期バージョンの CSV テンプレートは `templates/` ディレクトリ配下に配置しています。設計方針や技術的制約の詳細は [`docs/design.md`](docs/design.md)、実装の進め方については [`plan.md`](plan.md) を参照してください。

## Development

```sh
swift test
swift build -c release
```

CI（GitHub Actions）では macOS ランナー上でユニットテストおよびリリースビルド（`release build`）を実行します。`v*` タグのプッシュ時には、ビルドされた Apple Silicon 向けバイナリとチェックサム（SHA-256）を GitHub Releases に自動添付します。
