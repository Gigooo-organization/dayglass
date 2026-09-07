# チーム向け工数ログ 設計書（2026-09-07 決定）

「Apple Silicon Mac を使うメンバー全員に配布し、各自が管理部へ提出する工数集計を作るための OSS」を
**新しいリポジトリ**で作る。axlog-prototype はそのまま個人用として残し、使える部品だけ移植する。
この文書は**何を作るか**と**なぜそう決めたか**を持つ。実装の段取りは同じディレクトリの `plan.md`。
どちらも新リポジトリの立ち上げ時にそちらへ移す。

## 1. 目的と前提

- 記録するもの: AI エージェント（Claude Code / Codex / cursor-agent）の利用と、それ以外の PC 操作
- 出力: OpenTelemetry 形式のログ（手元）と、管理部へ提出する集計データ
- 配布先: チームメンバー。全員 Apple Silicon の MacBook
- 提出先: 管理部。受け取るのは集計であって生ログではない

個人用プロトタイプ（AX ツリー・クリック・自宅サーバ・DeepSeek 要約）からの最大の変更は
**データ最小化**と**サーバ非依存**。同僚に配る道具は、記録の中身を一文で説明できる必要がある。

## 2. 決定事項

| 論点 | 決定 | 理由 |
|---|---|---|
| 提出内容 | 日×プロジェクト×時間 ＋ AI 利用の内訳 ＋ 作業内容の文章 | 管理部の要求。文章は人が確認してから出す |
| PC 操作の粒度 | 前面アプリ ＋ ウィンドウタイトル ＋ URL ホスト ＋ アイドル/ロック/スリープ | プロジェクト推定に必要な最小限。クリック・打鍵・AX ツリー・選択テキストは記録しない |
| データの置き場 | Mac 内で完結。外に出るのは提出物だけ | サーバ不要。プライバシーの説明が最も簡単 |
| AI の取り込み | hooks ＋ 手元トランスクリプト解析（v1 の主経路）と、ネイティブ OTLP 受信の両方 | hooks は 3 ツール共通。OTLP 受信で Claude Code / Codex の実時間指標も取る |
| Collector | 必須にしない | Homebrew に formula が無く配布が重い。ファイルは Collector 互換形式にして後付け可能にする |
| 会議時間 | v1 は Zoom / Meet / Teams が前面の時間を `meeting` とする。カレンダー連携は v2 | PC 操作からは会議の実体が見えない |
| 実装言語 | Mac 上は Swift 単一バイナリ `dayglass`（daemon / hook / serve / report） | メンバーに Python 環境を要求しない |
| リポジトリ | 新リポジトリで開発。プロトタイプは触らない | desktop-1 / Tailscale / gocryptfs / DeepSeek 要約はチーム前提に合わず、切り離すより新しく始める方が履歴も設定も綺麗 |
| プロンプト本文 | 既定で記録しない。文字数のみ | Claude Code `OTEL_LOG_USER_PROMPTS`、Codex `log_user_prompt` の既定と揃える |
| 名前 | `dayglass`（1 日の砂時計） | 時間が落ちていくさまを黙って見ている道具。GitHub / Homebrew に先客なし |
| 署名 | 個人ビルド。Developer ID なし | 更新時に Accessibility の再許可が要る。README に明記 |
| 提出様式 | 仮の CSV から始める | 管理部の様式は未定。`templates/` で差し替え可能にする |
| ライセンス | MIT | |

## 3. アーキテクチャ

```
[Mac ローカル]
  dayglass daemon      前面アプリ・タイトル・URL ホスト・アイドル/ロック/スリープ → focus / afk span
  dayglass hook <tool> Claude Code / Codex / Cursor の hooks から起動 → gen_ai.session / gen_ai.turn span
  dayglass serve       127.0.0.1:4318 で OTLP/HTTP (JSON) を受信 → 同じファイルに追記
        │
        ▼  OTLP/JSON Lines
  ~/Library/Application Support/dayglass/otlp/YYYY-MM-DD/{traces,logs,metrics}.jsonl
        │
        ▼
  dayglass report      日×プロジェクト×区分の工数表 + AI 指標（csv / json / md / otlp-metrics）
  skill dayglass-report  Claude Code / Codex 上で動く。report と手元トランスクリプトから提出物を作り、
                      未割当を人に確認して確定する
        │
        ▼
[管理部]  集計ファイルのみ
```

`daemon` と `serve` は同一プロセス（launchd の 1 エージェント）で動かし、ファイルへの追記は
1 本の直列キューに集める。`hook` は別プロセスなので、`daemon` が持つ UNIX ドメインソケットへ
渡すか、居なければ自分で追記する（ファイルロックで直列化）。**どの経路でも書式は同じ**。

## 4. ログ形式

### 4.1 ファイル

- 置き場: `~/Library/Application Support/dayglass/otlp/<YYYY-MM-DD>/` （日付はローカル時刻で切る）
- `traces.jsonl` / `logs.jsonl` / `metrics.jsonl`。1 行が OTLP の Export リクエスト
  （`{"resourceSpans":[...]}` / `{"resourceLogs":[...]}` / `{"resourceMetrics":[...]}`）
- これは OTel Collector の `file` exporter が書き、`otlpjsonfile` receiver が読む形式そのもの。
  中央集約に切り替えるときは Collector を足すだけでよい
- 各行は書き終わりで `\n`。途中で切れた末尾行は読み手が捨てる（既存 `sealAbandoned` と同じ規則）
- 保持期間: 既定 90 日。`dayglass reap` が日付ディレクトリ単位で消す

### 4.2 Resource 属性

| 属性 | 値 |
|---|---|
| `service.name` | `dayglass` |
| `service.version` | バイナリのバージョン |
| `dayglass.source.id` | 端末ごとのランダム固定 ID（既存 `source.json` を流用） |
| `dayglass.member` | 設定ファイルで任意に指定。提出物の名義 |
| `os.type` | `darwin` |

ホスト名・ユーザ名は入れない。提出物に端末が特定できる情報を混ぜない。

### 4.3 Span（時間を持つもの。工数の本体）

| span 名 | 属性 | 発生源 |
|---|---|---|
| `focus` | `app.bundle_id`, `app.name`, `window.title`, `url.domain`, `dayglass.project`, `dayglass.category` | daemon |
| `afk` | `dayglass.afk.reason` = `idle` / `locked` / `sleep` | daemon |
| `dayglass.run` | daemon の起動から終了まで。記録の空白と活動の空白を区別する | daemon |
| `gen_ai.session` | `gen_ai.system` (`anthropic` / `openai` / `cursor`), `gen_ai.agent.name` (`claude-code` / `codex` / `cursor-agent`), `gen_ai.conversation.id`, `gen_ai.request.model`, `vcs.repository.url.full`, `vcs.ref.head.name`, `dayglass.cwd`, `dayglass.project` | hook |
| `gen_ai.turn` | 親は `gen_ai.session`。`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `dayglass.prompt.chars`, `dayglass.tool_calls` | hook（境界）＋ report 時にトランスクリプトで補完 |

`gen_ai.*` と `vcs.*` は OTel Semantic Conventions の名前。独自属性は `dayglass.` 接頭辞に限る。

`window.title` と `url.domain` は**手元にだけ**残る。`dayglass report` の出力には
`dayglass.project` と `dayglass.category` しか出ない。

### 4.4 Log（点のイベント）

`event.name` 付きの LogRecord。再集計とデバッグ用で、提出には使わない。

- `window.changed`（app, title, url.domain）— 既存イベントの縮小版
- `session.started` / `session.ended`
- `hook.<tool>.<event>`（hooks が受け取った生の `hook_event_name` と `session_id`。cursor-agent の対応状況を確かめる材料）
- `otlp.received`（`serve` が受けたリクエストの件数と送り元 `service.name`）

### 4.5 Metric

手元では生成しない。`dayglass report --format otlp-metrics` が集計時に作る:

- `dayglass.work.duration`（秒）属性: `dayglass.project`, `dayglass.category`, `dayglass.ai_assisted`
- `dayglass.ai.sessions` / `dayglass.ai.turns` / `gen_ai.client.token.usage`

管理部が OTLP を直接受ける場合にだけ意味を持つ。

### 4.6 ネイティブ OTLP 受信

`dayglass serve` は `127.0.0.1:4318` で `POST /v1/{traces,logs,metrics}` を受け、
`Content-Type: application/json` のみ受理する。protobuf は受けない（両ツールとも JSON を選べる）。

- Claude Code: settings.json の `env` で `CLAUDE_CODE_ENABLE_TELEMETRY=1`,
  `OTEL_METRICS_EXPORTER=otlp`, `OTEL_LOGS_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`,
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318`
- Codex: `config.toml` の `[otel]` で `exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "json" } }`。
  `metrics_exporter` は既定が OpenAI 宛て（statsig）なので `otlp-http` に明示する
- 受けた本文は**そのまま**その日の `logs.jsonl` / `metrics.jsonl` に追記する。変換しない。
  Claude Code の `claude_code.api_request`（トークン・コスト）と Codex の `codex.sse_event` は
  report 時にトランスクリプト由来の値と突き合わせ、どちらか一方があれば使う

受け口が居ないときは両ツールとも送信失敗を黙って捨てるので、hooks とトランスクリプトが
常に下支えになる。これが「hooks を主経路にする」理由。

## 5. エージェント取り込み

### 5.1 hooks 対応表

| 意味 | Claude Code | Codex | cursor-agent |
|---|---|---|---|
| セッション開始 | `SessionStart` | `SessionStart` | `sessionStart` |
| プロンプト送信 | `UserPromptSubmit` | `UserPromptSubmit` | `beforeSubmitPrompt` |
| ターン終了 | `Stop` | `Stop` | `stop` |
| セッション終了 | `SessionEnd` | `SessionEnd` | `sessionEnd`（`duration_ms` あり） |
| 共通で取れるもの | `session_id`, `cwd`, `transcript_path` | 同左 ＋ `model`, `turn_id` | `conversation_id`, `workspace_roots`, `transcript_path`, `model` |
| 設定場所 | `~/.claude/settings.json` の `hooks` | `~/.codex/hooks.json`（`[features] hooks = true`、`/hooks` で信頼登録） | `~/.cursor/hooks.json` |

すべて `dayglass hook <tool>` を `async` で呼ぶ。hook は stdin の JSON を読み、上の意味に正規化して
`gen_ai.session` / `gen_ai.turn` の開始・終了を記録する。**エージェントの応答を遅らせない**。

**cursor-agent は CLI での対応イベントが公式に一覧されていない**。`hook.cursor.*` ログを見て
実機で確かめる工程を plan に入れる。`sessionStart` が来なければ `beforeSubmitPrompt` の
初回をセッション開始とみなす。

Codex の `notify` はレガシー（削除予定）なので使わない。

### 5.2 トランスクリプト解析（report 時）

hooks は境界しか知らないので、トークン数・ツール呼び出し数・作業内容は手元のトランスクリプトから読む。

| ツール | 場所 | 読むもの |
|---|---|---|
| Claude Code | `~/.claude/projects/<slug>/<session>.jsonl` | `type=assistant` の `message.usage`、`cwd`、`gitBranch`、`type=user` の本文（文章生成用） |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`（`.zst` 圧縮あり） | `session_meta`（cwd, git）、`turn_context`（model）、`token_usage_record`、`user_message` / `item_completed` |
| cursor-agent | `~/.cursor/chats/<ws>/<chat>/store.db`、`~/.cursor/ai-tracking/ai-code-tracking.db` | 非公式。`conversation_summaries`（title / tldr）があれば文章生成に使う。トークン数は取れない |

**Claude Code の形式は公式に「内部形式で変わりうる」と明記されている**。解析は
`agent_session_evidence.py` の流儀（知らないキーは無視、壊れた行は数えて捨てる）を踏襲し、
失敗しても hooks 由来の境界だけで集計が成立するようにする。

## 6. 集計方法

### 6.1 稼働時間

1. `focus` span を時系列に並べ、`afk` と重なる部分を除く
2. 無操作（`CGEventSourceSecondsSinceLastEventType`）が **5 分**続いたら `afk`。画面ロックとスリープは即時
3. 2 分未満の途切れは結合する（ActivityWatch と同じ考え方）
4. 日付境界はローカル時刻の 0 時で切る

### 6.2 プロジェクト割当

各メンバーの `~/.config/dayglass/projects.toml` に「パターン → 管理部のプロジェクトコード」を持つ。

```toml
[[project]]
code = "PJ-1234"
name = "オフラインカルテ"
git = ["github.com/org/offline-karte-*"]
title = ["offline-karte", "オフラインカルテ"]
url = ["karte.example.com"]
```

優先順位:

1. 重なっている `gen_ai.session` の `vcs.repository.url.full` / `dayglass.cwd`
2. ターミナル・エディタのウィンドウタイトルに含まれるリポジトリ名
3. `url.domain` の規則
4. 手動メモ `dayglass note --from 14:00 --to 15:30 --project PJ-1234 "打合せ"`
5. 未割当

割当は **report 時**に行う。daemon は推定しない。規則を直せば過去分も直る。

### 6.3 区分

| 区分 | 判定 |
|---|---|
| `ai_assisted` | `gen_ai.turn` が走っている時間。またはエージェントを動かしている端末アプリが前面の時間 |
| `coding` | エディタ・端末が前面（AI ターン外） |
| `meeting` | Zoom / Meet / Teams / FaceTime が前面 |
| `communication` | Slack / メール / チャットが前面 |
| `browsing` | ブラウザが前面で、上のどれでもない |
| `other` | それ以外 |

bundle ID → 区分の既定表を持ち、`projects.toml` と同じファイルで上書きできる。

### 6.4 AI 指標

- AI 利用時間の割合（`ai_assisted` / 稼働時間）
- セッション数・ターン数（`gen_ai.session` / `gen_ai.turn`）
- トークン数（トランスクリプト、または OTLP 受信の `api_request` / `sse_event`。両方あれば OTLP 優先）
- コストは出さない（管理部の要求に無い。価格表の保守が要る）

### 6.5 出力

`dayglass report --month 2026-09 --format csv|json|md|otlp-metrics`

- 行: 日 × プロジェクト × 区分
- 列: 時間（15 分丸め、設定可）、AI セッション数、AI ターン数、トークン数
- `--unassigned` で未割当の時間帯を候補付きで列挙する（skill が人に聞く材料）

## 7. Skill `dayglass-report`

Claude Code と Codex の両方で動く `SKILL.md`。**外部 LLM API は使わない**。メンバーが
すでに使っているエージェントが要約器になる。

1. `dayglass report --month <月> --format json` と `--unassigned` を実行
2. 未割当の時間帯を候補付きで人に確認し、`projects.toml` か `dayglass note` で確定
3. 作業内容の文章は、日ごとに手元トランスクリプトから「依頼と結果」を伏字付きで抜き出して要約する
   （`agent_session_evidence.py` の抽出・伏字規則を Swift に移植した `dayglass evidence --day` を使う）
4. 管理部の様式に整形して出力。様式はテンプレートとして `templates/` に置き、差し替え可能にする
5. 提出前に人が読む。skill は「確認してから提出してください」で終わる

## 8. プライバシー境界

- 記録しない: 打鍵、クリック、選択テキスト、AX ツリー、プロンプト本文、スクリーンショット
- 手元にだけ残る: ウィンドウタイトル、URL ホスト、cwd、リポジトリ URL
- 提出物に出る: プロジェクトコード、区分、時間、AI 指標、人が確認した文章
- 除外: パスワードマネージャ等は bundle 単位で既定除外（既存）。ブラウザ拡張の描画は `withheld_labels` 相当をタイトルに適用
- 伏字: 文章生成の出口で 1 回だけ掛ける。境界は ASCII で書く（既存の `(?<![A-Za-z0-9_])` の教訓）
- 一時停止: `dayglass pause 1h`。私用の時間を記録しない手段を最初から持つ

## 9. 配布とインストール

- `brew install gigooo-organization/tap/dayglass` を目標。ソースビルドの formula（各自の Mac でビルドする）
- **署名は個人ビルド前提**（Developer ID は使わない）。Accessibility 権限は署名 ID に紐づくので、
  固定パスへコピーして自己署名し（プロトタイプ `install.sh` の方式）、更新のたびに再許可が要ることを README に書く
- `dayglass setup` が launchd の登録、hooks の追記（3 ツール）、settings.json / config.toml の OTel 設定、
  `source.json` の生成、`projects.toml` の雛形をまとめて行う。既存設定は壊さず追記する

## 10. プロトタイプから移植するもの

コピーではなく、テストごと移して新リポジトリの流儀に合わせる。

| プロトタイプ | 移植先 | 備考 |
|---|---|---|
| `AxlogCore/SegmentClock`, `JSONLEncoder`, `Segmenter.sealAbandoned` | `DayFile` | 10 分バケットは捨て、日付ファイルへ。末尾行の切り捨て規則はそのまま |
| `AxlogCore/ChurnFilter`, `RepeatFilter` | daemon | タイトルのスピナー抑制 |
| `axlogd/WindowMonitor`, `AXAttributes`（URL 取得） | daemon | app / title / url.domain だけ残す |
| `axlogd/SegmentSealer` の時計ティック | daemon | 開いた span を時間で閉じる |
| `main.swift` の除外 bundle、TCC 権限確認 | daemon | |
| `scripts/install.sh`（固定パス＋自己署名） | `dayglass setup` | Developer ID が無い場合の経路 |
| `scripts/install-session-export.sh` の `source.json` 生成 | `dayglass setup` | 端末 ID |
| `server/agent_session_evidence.py`（抽出・伏字・`merge_turns`）とテスト | `dayglass evidence` | Python → Swift。伏字の ASCII 境界規則を落とさない |
| `server/timeline.py` の `withheld_labels`, `redactions` | daemon / evidence | タイトルと文章の出口に適用 |
| `ssh/`, `server/axlog.py`, `summarise.py`, `store.py`, gocryptfs 一式 | 移植しない | サーバ前提 |
| `InputMonitor`, `AXTree*`, `AXTextDiff`, `AXSnapshotPolicy`, `KeyChord`, `selection` | 移植しない | 記録しない粒度 |

## 11. 測ってから決めること

- cursor-agent の CLI で実際に届く hook イベント
- Claude Code と Codex のネイティブ OTLP が JSON で本当に届くか、1 日あたりの行数とバイト数
- アイドル閾値 5 分と結合閾値 2 分が実データで妥当か
- タイトルからのリポジトリ名推定の的中率（AI セッションの cwd と突き合わせて測れる）
