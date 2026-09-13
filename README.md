# dayglass

1 日の砂時計。Mac の前で時間がどこに落ちていったかを黙って記録し、
管理部に出す工数集計を各自の手元で作るための道具。Apple Silicon Mac 向け。

## 記録するもの・しないもの

**記録する**

- 前面にあるアプリ、ウィンドウタイトル、URL のホスト名（パスは GitHub など許可したホストだけ）
- アイドル・画面ロック・スリープ・一時停止の時間帯
- Claude Code / Codex のセッションとターンの境界、モデル名、トークン数
- GitHub（Gigooo-organization 配下）での自分の活動の種類と日時

**記録しない**

- 打鍵、クリック、選択したテキスト、スクリーンショット
- AI へのプロンプト本文と応答本文（文字数だけ）、ツールの引数と出力
- URL のクエリパラメータ、許可していないホストのパス

生データは Mac の外に出ない。dayglass 自身は外部へ送信せず、管理部へ渡すのは
`dayglass report --freeze` が作る集計を本人が手で提出する。そこにはプロジェクトコード・区分・時間・
確信度・AI 指標・成果物の件数と、本人が確認した作業内容の文章しか含まれない。

集計の確定に skill（Claude Code / Codex 上で動く）を使う場合、集計結果と確認用の質問、
伏字済みの作業抜粋がそのエージェントのモデル API に送られる。送る範囲は `docs/design.md` §8 を参照。

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
