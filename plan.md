# 実装計画 — チーム向け工数ログ

設計は同じディレクトリの `design.md`。ここは段取りだけ。**新リポジトリ**で進め、axlog-prototype は
触らない。各フェーズは TDD で進め、`AxlogCore` に純粋ロジックを置き、`dayglass` バイナリは薄い殻にする。

## フェーズ 0: 新リポジトリの立ち上げ

- [x] リポジトリ作成（`dayglass`、ローカルのみ）。`design.md` を `docs/` に移す
- [ ] `Package.swift`: `dayglass` 単一実行ファイル（サブコマンド）＋ `AxlogCore` ＋ テスト。macOS 13 以上、Swift 6
- [ ] LICENSE（MIT）、`.gitignore`、README の骨（何を記録し、何を記録しないかを最初に書く）
- [ ] `AxlogCore/OTLP/`: OTLP/JSON の型（Resource, Span, LogRecord, Metric）と JSON Lines 書き出し。
      テスト: 1 span が `{"resourceSpans":[...]}` 1 行になる。属性の型（string / int / bool）が OTLP の `anyValue` 形式になる
- [ ] `AxlogCore/DayFile`: 日付ディレクトリへの追記、`\n` 終端、途中で切れた末尾行の切り捨て
      （プロトタイプ `Segmenter.sealAbandoned` をテストごと移植）
- [ ] プロトタイプから `SegmentClock` の時刻書式、`ChurnFilter`、`RepeatFilter` をテストごと移植

## フェーズ 1: daemon（PC 操作）

- [ ] `WindowMonitor` を縮小: app / title / url.domain のみ。AX ツリー・InputMonitor・selection は外す
- [ ] `IdleMonitor`: `CGEventSourceSecondsSinceLastEventType`、画面ロック通知、スリープ通知 → `afk` span
- [ ] `FocusTracker`（純粋）: window.changed の列と afk の列から `focus` span を組み立てる。
      テスト: 同一 app 連続は 1 span、afk で切れる、daemon 終了で閉じる
- [ ] `dayglass.run` span と `session.started/ended` log
- [ ] `ChurnFilter` を title に適用（スピナーで span を割らない）
- [ ] 除外 bundle と `withheld_labels` 相当を title に適用
- [ ] `dayglass pause <期間>`

## フェーズ 2: hooks（AI エージェント）

- [ ] `dayglass hook claude|codex|cursor`: stdin JSON → 正規化（HookEvent: sessionStart / promptSubmit / turnEnd / sessionEnd）。
      テスト: 3 ツールの実ペイロード（fixtures）から同じ HookEvent が出る
- [ ] `gen_ai.session` / `gen_ai.turn` span の開始・終了を状態ファイルで追跡（hook は毎回別プロセス）
- [ ] `hook.<tool>.<event>` log を必ず残す（cursor の実機確認用）
- [ ] daemon への UNIX ソケット渡し。daemon が居なければ自分で追記（flock）
- [ ] `dayglass setup hooks`: 3 ツールの設定ファイルへ追記。既存の hooks を壊さない。
      テスト: 既存 hooks がある settings.json / hooks.json に追記しても他が残る
- [ ] 実機で cursor-agent の届くイベントを記録し、`docs/design.md` §5.1 を実測で更新

## フェーズ 3: OTLP 受信

- [ ] `dayglass serve`: 127.0.0.1:4318、`POST /v1/{traces,logs,metrics}`、JSON のみ、本文をそのまま当日ファイルへ
- [ ] `otlp.received` log
- [ ] `dayglass setup telemetry`: Claude Code settings.json `env` と Codex `[otel]` を書く
- [ ] 実機で 1 日回し、行数・バイト数を測って保持期間の既定を決める

## フェーズ 4: 集計

- [ ] `AxlogCore/Report/`: 
  - `ActiveTime`: focus − afk、2 分未満結合、日付境界。テスト: 境界をまたぐ span、afk と部分重なり
  - `ProjectRules`: `projects.toml` の読み込みと優先順位付き割当。テスト: git > title > url > note > 未割当
  - `Category`: bundle → 区分、AI ターン重なりで `ai_assisted`
  - `Rounding`: 15 分丸め（日合計で丸め、行ごとの丸め誤差を合計に出さない）
- [ ] トランスクリプト読み取り: Claude `message.usage`、Codex `token_usage_record`（`.zst` 対応）。知らないキーは無視
- [ ] `dayglass report --month --format csv|json|md|otlp-metrics`、`--unassigned`
- [ ] `dayglass note`
- [ ] `dayglass evidence --day`: プロトタイプ `server/agent_session_evidence.py` の抽出・伏字・`merge_turns` を Swift へ移植。
      `server/tests/test_agent_session_evidence.py` の各ケースも移す

## フェーズ 5: skill と配布

- [ ] `skills/dayglass-report/SKILL.md`（Claude Code / Codex 両対応）と `templates/` の様式
- [ ] `dayglass setup` の統合（launchd / hooks / telemetry / source.json / projects.toml 雛形）
- [ ] Homebrew tap の formula、README を配布向けに書き直す
- [ ] 個人ビルドの署名手順（固定パス＋自己署名、更新時の再許可）を `dayglass setup` と README に

## 未決

- 新リポジトリの名前（`dayglass` のままか、別名か）
- Apple Developer Program の有無（署名方針）
- 管理部の様式（Excel か CSV か、列の並び）。`templates/` の初版は仮置きで作る
- ライセンス
