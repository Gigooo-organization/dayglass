# 実装計画 — チーム向け工数ログ

設計は `docs/design.md`。ここは段取りだけ。axlog-prototype は触らない。
各フェーズは TDD で進め、`DayglassCore` に純粋ロジックを置き、`dayglass` バイナリは薄い殻にする。

フェーズの順序は design.md §11 に従う。**集計（report → questions → note → freeze）を人工データで先に通し、
その後に取り込み経路（hooks → daemon → OTLP 受信）を足す**。集計が正しいことを確かめずに収集を作らない。

## フェーズ 0: 土台

- [x] リポジトリ作成。`design.md` を `docs/` に移す
- [x] `Package.swift`: `dayglass` 単一実行ファイル ＋ `DayglassCore` ＋ テスト。macOS 13 以上、Swift 6
- [x] LICENSE（MIT）、`.gitignore`
- [x] README の骨（何を記録し、何を記録しないかを最初に書く）
- [x] `DayglassCore/OTLP/`: OTLP/JSON の型（Resource, Span, LogRecord, Metric）と JSON Lines 書き出し。
      テスト: 1 span が `{"resourceSpans":[...]}` 1 行になる。属性の型（string / int / bool）が OTLP の `anyValue` 形式になる
- [x] `DayglassCore/DayFile`: 日付ディレクトリへの追記、`\n` 終端、途中で切れた末尾行の切り捨て
      （プロトタイプ `Segmenter.sealAbandoned` をテストごと移植）
- [x] 書き込み経路 `Sink`: daemon の UNIX ソケットへ渡す。居なければ flock で直接追記。hook / sync github で共有（§3）
- [x] プロトタイプから `SegmentClock` の時刻書式、`ChurnFilter`、`RepeatFilter` をテストごと移植

## フェーズ 1: 集計（人工データで通す）

人工データは `Tests/Fixtures/` に OTLP/JSON Lines として置く。§11 の網羅ケース: 並列 AI セッション、
会議中の別アプリ操作、資料閲覧・思索の無操作、daemon 停止の欠測、日跨ぎ、`paused`。

- [x] `DayglassCore/Report/`
  - `ActiveTime`: focus − afk（`paused` 含む）、日付境界、`dayglass.run` 不在は `missing`。
    テスト: 境界をまたぐ span、afk と部分重なり、欠測と afk の区別
  - `ProjectRules`: `projects.toml` の読み込みと優先順位付き割当（§6.2）。
    テスト: note > title/url > session > 未割当。並列セッションが別プロジェクトなら未割当 ＋ `ambiguous_project`。
    ブラウザ前面ではバックグラウンドのセッションで判定しない。`project_basis` が正しく付く
  - `CategoryRules`: bundle / url.domain / url.path → 区分（§6.3）。
    テスト: Meet はブラウザ URL で `meeting`、GitHub `/pull/` は `review`、`category_basis` が正しく付く
  - `AIOverlap`: 稼働時間と `gen_ai.turn` の重なり（§6.4）。AI 時間は人の時間に合算しない
  - `Rounding`: 日合計を 15 分で丸め、行へ最大剰余法で配分（§6.6）。
    テスト: 行の合計が日合計と一致、`confidence` 内訳も一致
  - `Questions`: `unassigned` / `ambiguous_project` / `ambiguous_category` / `gap` / `missing` の生成（§6.7）。
    テスト: id が決定論的、閾値未満は出ない、`gap` の候補順が `afk.reason` で変わる、日付順に並ぶ
  - `Notes`: `notes/<YYYY-MM>.jsonl` の読み書き。時間帯の重なりで適用、後勝ち、`--skip` は除外。
    テスト: 閾値を変えて質問の境界がずれても、回答済みの時間帯は再質問されない
- [x] `dayglass report --month --format csv|json|md|otlp-metrics`、`--table time|ai|output`、`--questions`、`--no-titles`
- [x] `dayglass note --question | --from --to | --skip | --day --summary`
- [x] `dayglass report --freeze`: `submissions/<YYYY-MM>/` に全フォーマット ＋ `projects.toml` / notes スナップショット ＋ バージョン
- [x] `templates/` に仮の CSV 様式
- [x] 人工データで report → questions → note → freeze を最後まで通す（§11 の第一項）

## フェーズ 2: AI 取り込み（hooks ＋ トランスクリプト）

まず Claude Code 一種類で 1 日分を通し、次に Codex。

- [x] `dayglass hook claude|codex`: stdin JSON → 正規化（HookEvent: sessionStart / promptSubmit / turnEnd / sessionEnd）。
      テスト: 両ツールの実ペイロード（fixtures）から同じ HookEvent が出る
- [x] `gen_ai.session` / `gen_ai.turn` span の開始・終了を状態ファイルで追跡（hook は毎回別プロセス）
- [x] `hook.<tool>.<event>` log を必ず残す（hook 仕様変更の検知用）
- [x] トランスクリプト読み取り（§5.2）: Claude `message.usage` / `cwd` / `gitBranch`、Codex `token_usage_record` / `session_meta`（`.zst` 対応）。
      知らないキーは無視、壊れた行は数えて捨てる、`<system-reminder>` はユーザー入力にしない。
      `edit_calls` / `tool_calls` の算出
- [x] トークン列の正規化（§6.4 の 4 列）。テスト: Claude と Codex で `input_uncached` の意味が揃う
- [x] `dayglass setup hooks`: 両ツールの設定ファイルへ追記。既存の hooks を壊さない。
      テスト: 既存 hooks がある settings.json / hooks.json に追記しても他が残る
- [ ] 実機で通常の対話セッション 1 件を起動から終了まで取り、report まで通す

## フェーズ 3: daemon（PC 操作）

- [x] `WindowMonitor` を縮小: app / title / url.domain / url.path（許可ホストのみ、クエリとフラグメントは捨てる）。
      AX ツリー・InputMonitor・selection は外す
- [ ] `IdleMonitor`: `CGEventSourceSecondsSinceLastEventType`、画面ロック通知、スリープ通知 → `afk` span。
      afk の開始は最終入力時刻に遡らせる（§6.1）
- [x] `FocusTracker`（純粋）: window.changed の列と afk の列から `focus` span を組み立てる。
      テスト: app / title / url.domain / url.path のどれかが変われば新 span、afk で切れる、daemon 終了で閉じる
- [x] `dayglass.run` span と `session.started/ended` log
- [x] `ChurnFilter` を title に適用（スピナーで span を割らない）
- [x] 除外 bundle、プライベートウィンドウ、`withheld_labels` 相当を title に適用
- [x] `dayglass pause <期間>` → `afk.reason = paused`
- [x] `dayglass reap`（既定 90 日）
- [ ] 実機で 1 日回し、report → questions → note → freeze を本物のデータで通す

## フェーズ 4: OTLP 受信、GitHub、evidence

- [x] `dayglass serve`: 127.0.0.1:4318、`POST /v1/{traces,logs,metrics}`、JSON のみ、4 MB 上限。
      許可リスト（§4.6）に載る属性だけ抽出して当日ファイルへ。テスト: probe の実ペイロードから本文・識別子が落ちる
- [x] `otlp.received` log（受信数、送り元、破棄数）
- [ ] OTLP とトランスクリプトのターン単位マージ（§6.4）。テスト: serve 停止区間が混在しても二重計上しない
- [x] `dayglass setup telemetry`: Claude Code settings.json `env` と Codex `[otel]` を書く
- [ ] 実機で対話型 TUI から OTLP が届くか確認し、1 日の行数・バイト数を測る（§11）
- [x] `dayglass sync github`: `/users/<me>/events` を gh で取り、`Gigooo-organization/` だけ `github.event` に。id で重複排除。
      launchd 日次 ＋ report 直前
- [x] 生産性指標（§6.5）: ローカル git のコミット数・変更行数、`gh search prs`、`PullRequestReviewEvent`
- [x] `dayglass evidence --day`: プロトタイプ `server/agent_session_evidence.py` の抽出・伏字・`merge_turns` を Swift へ移植。
      `server/tests/test_agent_session_evidence.py` の各ケースも移す。ASCII 境界のマスキングを再現

## フェーズ 5: skill、配布、試用

- [x] `skills/dayglass-report/SKILL.md`（Claude Code / Codex 両対応）。§7 の 9 手順、会議の手動登録確認を含む。
      候補を増やさない・`gap` を勝手に `meeting` にしない旨を明記
- [x] `dayglass setup` の統合（launchd / hooks / telemetry / source.json / projects.toml 雛形 / skill 配置 / Time Machine 除外）
- [x] Homebrew tap の formula（ソースビルド、`gh` 依存）、README を配布向けに書き直す。モデル API へ送る範囲を明記
- [x] 個人ビルドの署名手順（固定パス＋自己署名、更新時の再許可）を `dayglass setup` と README に
- [ ] 2〜3 名で 1〜2 週間試用し、§11 の負荷測定（確認時間の中央値、残存誤差、質問件数）を取る

## 未決

- 管理部の様式（Excel か CSV か、列の並び）。`templates/` の初版は仮置きで作る
