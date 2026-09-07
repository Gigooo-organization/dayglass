# dayglass

1 日の砂時計。Mac の前で時間がどこに落ちていったかを黙って記録し、
管理部に出す工数集計を各自の手元で作るための道具。Apple Silicon Mac 向け。

## 記録するもの・しないもの

**記録する**

- 前面にあるアプリ、ウィンドウタイトル、URL のホスト名
- アイドル・画面ロック・スリープの時間帯
- Claude Code / Codex / cursor-agent のセッションとターンの境界、モデル名、トークン数

**記録しない**

- 打鍵、クリック、選択したテキスト、スクリーンショット
- AI へのプロンプト本文と応答本文（文字数だけ）

生データは Mac の外に出ない。管理部へ渡すのは `dayglass report` が作る集計だけで、
そこにはプロジェクトコード・区分・時間・AI 指標しか含まれない。

## 形式

OpenTelemetry の OTLP/JSON Lines。`~/Library/Application Support/dayglass/otlp/<日付>/` に
`traces.jsonl` / `logs.jsonl` / `metrics.jsonl`。OTel Collector の `otlpjsonfile` receiver で
そのまま読める。

## 設計

`docs/design.md`。段取りは `plan.md`。

## ビルド

```sh
swift build
swift test
```
