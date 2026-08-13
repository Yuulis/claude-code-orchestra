# claude-code-orchestra

マルチエージェント AI 開発環境

```
Claude Code（オーケストレーター & プランナー）─┬─ Codex CLI（実装・設計相談）
                                               ├─ Claude サブエージェント（調査・分析: Opus / レビュー: Sonnet・Opus）
                                               └─ Antigravity CLI（クロスモデル・セカンドオピニオン — 任意）
```

## クイックスタート

既存プロジェクトのルートで実行します（事前に Codex のインストールとログインを済ませてください）：

```bash
codex --version && codex login && git clone --depth 1 https://github.com/Yuulis/claude-code-orchestra.git .starter && cp -r .starter/.claude .starter/.codex .starter/CLAUDE.md . && rm -rf .starter && claude
```

## 使い方

### 基本の流れ

このテンプレートを導入したプロジェクトで `claude` を起動すると、Claude Code が**オーケストレーター**として動きます。普段どおり日本語で依頼するだけで、裏側では次の役割分担で処理されます。

| フェーズ | 担当 | 補足 |
|----------|------|------|
| **計画（Planning）** | **Claude が主導・最終決定** | アーキテクチャ・データモデル・セキュリティ等の高難度設計では Codex（`gpt-5.6-sol`, effort high）に設計相談 |
| **実装** | **Codex サブエージェント** | `codex exec`（effort medium）。1ファイルの小修正は Claude が直接 |
| **レビュー** | **Sonnet サブエージェント**（デフォルト） | 高リスク変更（セキュリティ・アーキテクチャ・データモデル）は **Opus**。さらに `/codex:review` をクロスツールの追加レーンとして併用可 |
| **調査・情報収集** | **Opus サブエージェント**（主軸） | 必要に応じて Antigravity（`agy`）が補助 |
| **セカンドオピニオン** | **Antigravity CLI**（`agy`, Gemini 3.x） | 「セカンドオピニオン」「別のモデルで確認して」と言えば起動 |

レーンの正式定義（SSOT）: [`.claude/rules/model-routing.md`](.claude/rules/model-routing.md)

### 日常でよく使うコマンド

```
/feature ユーザープロフィール編集機能     # 機能追加の計画〜実装ルーティング
/team-execute                            # 承認済み計画の並列実装＋並列レビュー
/team-execute --review-only              # 既存の変更をレビューだけしたい時
/troubleshoot {エラーメッセージ}          # エラーの診断と修正計画
/spike WebSocket と SSE どちらを採用すべき？  # 技術調査（go/no-go 判断資料の作成）
/checkpointing                           # セッション終了時の記録・整理
/codex:review                            # Codex による追加コードレビュー（高リスク変更向け）
```

迷ったら普通に日本語で依頼すれば、hooks（`agent-router.py`）が適切な委譲先を提案します。

### 仕様書・実装状況のまとめ（docs/manual/）

「仕様書をまとめて」「実装状況をまとめて」と依頼すると、`docs/manual/<テーマ名>/` にテーマごとのディレクトリが作られ、**日本語の Markdown** で保存されます。規約: [`.claude/rules/manual-docs.md`](.claude/rules/manual-docs.md)

```
docs/manual/
├── auth-flow/          # テーマごとにディレクトリ
│   └── spec.md         # 日本語で記述
└── release-2026-07/
    └── status.md
```

### Codex 側から使う場合（sol / terra / luna）

Claude を介さず Codex CLI をトップレベルで使う場合は `.codex/AGENTS.md` §8 のルーティングに従います：

- **Planning** → `gpt-5.6-sol`（effort **high 以上**。`.codex/config.toml` のデフォルト）
- **実装・レビュー** → `gpt-5.6-sol` の **low/medium** effort を主軸に、タスク特性で振り分け：
  - `gpt-5.6-luna`（low）— 判断の余地が小さく機械的に検証できる大量処理（分類・ラベル付け・定型抽出・短い変換/要約）
  - `gpt-5.6-terra`（low/medium）— 日常業務（一般的な feature 実装・テスト追加・リファクタリング・ドキュメント/コードレビュー）
  - `gpt-5.6-sol`（high+）— やり直しコストが高い難問（横断的設計変更・難再現バグ・セキュリティレビュー）
- モデルを明示指定された場合はそれに従う。迷う場合はユーザーに確認してよい
- 呼び出し単位の上書き: `-m <model>` / `-c model_reasoning_effort=<none|minimal|low|medium|high|xhigh|max>`

### モデルの変更方法

モデルはすべて `.claude/settings.json` の `env` に集約されています。**この値を書き換えるだけ**で全スキル・フック・エージェントに反映されます（個別ファイルの編集は不要。反映は次回セッション起動から）：

```jsonc
"env": {
  "CODEX_MODEL": "gpt-5.6-sol",        // Codex デフォルト（設計相談・複雑実装）
  "CODEX_MODEL_TERRA": "gpt-5.6-terra", // 日常実装/レビューの代替レーン
  "CODEX_MODEL_LUNA": "gpt-5.6-luna",   // 機械的大量処理の代替レーン
  "CODEX_RESCUE_MODEL": "gpt-5.6-terra",// /codex:rescue 用（安価リトライ）
  "CODEX_PLAN_EFFORT": "high",          // 設計相談時の reasoning effort
  "CODEX_IMPL_EFFORT": "medium",        // 実装・レビュー時の reasoning effort
  "ANTIGRAVITY_MODEL": "gemini-3.1-pro" // セカンドオピニオン用
}
```

> `CLAUDE_CODE_SUBAGENT_MODEL` は**意図的に未設定**です。設定するとサブエージェントの個別モデル指定（レビュアーの Sonnet/Opus 使い分け）が上書きされ効かなくなります。

### 新しいプロジェクトでの初期設定

1. クイックスタートのワンライナーでテンプレートを導入
2. Claude Code 内で `/init` を実行 → 技術スタックの自動検出、`DESIGN.md`（要件定義書）と CLAUDE.md Zone B の初期化
3. 開発開始。セッション終了時は `/checkpointing` で記録
4. テンプレート更新は `./scripts/update.sh`（Zone B/C のローカル内容は保持されます）

## 前提ツール

### Claude Code

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

### Codex CLI

```bash
npm install -g @openai/codex
codex login
```

### Antigravity CLI（任意）

Google の Antigravity CLI（`agy`、Gemini CLI の後継）は、クロスモデルのセカンドオピニオンを提供します — 高難度の設計・計画に対する Gemini 3.x による独立レビューと、対立する選択肢のタイブレークです。未インストールでもオーケストラは動作し、その場合レビューは Codex のみにフォールバックします。

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy --version && agy models   # インストールと認証の確認
```

ポリシー: `.claude/rules/antigravity-delegation.md`（いつ使うか）/ `.claude/skills/antigravity-system/`（どう使うか）

### Codex Plugin for Claude Code（任意）

Claude Code から Codex を直接使えるプラグインです。コードレビューやタスク委譲を簡単にします。

```bash
# Claude Code 内で実行
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

**利用できるコマンド：**
- `/codex:review` — コードレビュー
- `/codex:adversarial-review` — 設計への挑戦的レビュー
- `/codex:rescue` — タスク委譲
- `/codex:status` / `/codex:result` / `/codex:cancel` — ジョブ管理

### AI CLI を最新に保つ

Claude Code と Codex CLI はリリース頻度が高く、マイナーバージョン間でもモデル名・フラグ・sandbox の挙動が変わります。**作業セッションの前に両方を更新してください。**

```bash
# Claude Code（組み込みのセルフアップデート）
claude update

# Codex CLI
npm install -g @openai/codex@latest

# Antigravity CLI（インストール済みの場合）
agy update
```

更新後にバージョンを確認します：

```bash
claude --version && codex --version && agy --version
```

Codex と Antigravity のモデルは `.claude/settings.json`（`env.CODEX_MODEL` / `env.ANTIGRAVITY_MODEL`）に一元化されており、すべての `${CODEX_MODEL:-...}` / `${ANTIGRAVITY_MODEL:-...}` 参照はここに解決されます。最新モデルを使いたい場合はこの値（例: `gpt-5.6-sol`、`gemini-3.1-pro`）を書き換えるだけで、個別のスキルファイルを編集する必要はありません。`${...:-default}` の fallback は env 変数が未設定のときの既定値にすぎません。追加のレーン変数として `CODEX_MODEL_TERRA` / `CODEX_MODEL_LUNA`（日常業務／機械的処理の代替）、`CODEX_RESCUE_MODEL`、effort の既定値 `CODEX_PLAN_EFFORT` / `CODEX_IMPL_EFFORT` があります。レーン全体の定義は `.claude/rules/model-routing.md` を参照してください。

## アーキテクチャ

```
┌─────────────────────────────────────────────────────────────┐
│      Claude Code（オーケストレーター — 1M コンテキスト）      │
│      → コンテキスト温存が最優先                              │
│      → ユーザー対話・調整・計画の主導・小規模編集を担当       │
│                      ↓                                      │
│  ┌──────────────────────┐                                   │
│  │  サブエージェント      │                                  │
│  │  general-purpose (Opus)│                                 │
│  │  → 調査・分析          │                                  │
│  │  → Codex への委譲      │                                  │
│  │  → マルチモーダル処理   │                                  │
│  │  レビュアー (Sonnet/Opus)│                                │
│  │  ┌──────────────┐    │                                   │
│  │  │  Codex CLI   │    │                                   │
│  │  │  実装         │    │                                   │
│  │  │  設計相談     │    │                                   │
│  │  │  デバッグ     │    │                                   │
│  │  └──────────────┘    │                                   │
│  └──────────────────────┘                                   │
└─────────────────────────────────────────────────────────────┘
```

### コンテキスト管理（重要）

メインのオーケストレーターのコンテキストを温存するため、大規模なタスクは適切なエージェントに委譲します。

| 状況 | 推奨される方法 |
|------|----------------|
| コードベース全体の分析 | **Opus サブエージェント**（1M コンテキスト） |
| 外部調査・サーベイ | **Opus サブエージェント**（WebSearch/WebFetch。必要に応じて agy が補助） |
| マルチモーダルファイル（PDF/画像） | Claude が直接。大規模分析は Opus サブエージェント |
| コード実装 | Codex サブエージェント（general-purpose 経由または直接 `codex exec`） |
| 計画（Planning） | Claude が主導。高難度設計は Codex に相談 |
| コードレビュー | Sonnet サブエージェント（高リスクは Opus）。`/codex:review` をクロスツールレーンとして併用可 |
| 高難度の設計・計画のセカンドオピニオン | サブエージェント → Antigravity CLI（`agy`） |
| 短い質問・回答 | 直接呼び出しで OK |
| 詳細な分析が必要 | サブエージェント経由 → 結果をファイルに保存 |

## ディレクトリ構成

```
.
├── CLAUDE.md                    # オーケストレーター契約（軽量。DESIGN.md と PROGRESS.md へリンク）
├── README.md
├── PROGRESS.md                  # 作業進捗のローリング記録 — 直近5チェックポイントの要約（/checkpointing が生成）
├── LICENSE
├── pyproject.toml               # Python プロジェクト設定
├── uv.lock                      # 依存関係ロックファイル
├── VERSION                      # テンプレートバージョン
│
├── docs/
│   └── manual/                  # 仕様書・実装状況の日本語まとめ（テーマごとのディレクトリ）
│
├── .claude/
│   ├── agents/
│   │   ├── general-purpose.md   # 実装・調査・Codex 委譲エージェント（Opus）
│   │   └── codex-debugger.md    # エラー分析エージェント（Opus）
│   │
│   ├── skills/                  # 再利用可能なワークフロー（15個）
│   │   ├── feature/             # 機能計画（existing/greenfield モード + 複雑度ルーティング）
│   │   ├── team-execute/        # Agent Teams による並列実装＋並列レビュー
│   │   ├── spike/               # 技術調査・実現可能性検証（意思決定文書の作成）
│   │   ├── plan/                # 実装計画の作成
│   │   ├── tdd/                 # テスト駆動開発
│   │   ├── simplify/            # コードリファクタリング
│   │   ├── codex-system/        # Codex CLI 統合
│   │   ├── antigravity-system/  # Antigravity CLI 統合（クロスモデル・セカンドオピニオン）
│   │   ├── design-tracker/      # 設計判断を検出して DESIGN.md に記録
│   │   ├── research-lib/        # ライブラリ調査
│   │   ├── update-lib-docs/     # ライブラリドキュメントの更新
│   │   ├── checkpointing/       # セッション永続化 + パターン発見 + コンパクトフェーズ
│   │   ├── catchup/             # オンボーディング用 GUIDE.md の生成
│   │   ├── init/                # プロジェクト初期化
│   │   └── troubleshoot/        # エラー診断・修正計画
│   │
│   ├── hooks/                   # 自動化フック（8個）
│   │   ├── agent-router.py      # エージェントルーティング
│   │   ├── lint-on-save.py      # 保存時の自動 lint
│   │   ├── error-to-codex.py    # エラー検出 → デバッガー提案
│   │   └── ...
│   │
│   ├── rules/                   # 開発ガイドライン
│   │   ├── model-routing.md     # モデル・effort レーン定義（SSOT）
│   │   ├── manual-docs.md       # docs/manual/ の日本語まとめ規約
│   │   ├── coding-principles.md
│   │   ├── testing.md
│   │   └── ...
│   │
│   ├── settings.json             # Claude Code 設定（hooks / permissions / env）
│   │
│   ├── docs/
│   │   ├── DESIGN.md            # 要件定義書（マクロな要件・設計）
│   │   ├── CODEX_HANDOFF_PLAYBOOK.md  # Codex 委譲テンプレート
│   │   ├── research/            # 調査結果（Opus サブエージェント）
│   │   └── libraries/           # ライブラリ制約
│   │
│   └── logs/                    # 実行時生成（.gitignore 対象）
│       └── cli-tools.jsonl      # Codex / Antigravity の入出力ログ
│
├── .codex/                      # Codex CLI 設定
│   ├── AGENTS.md
│   ├── config.toml
│   └── skills/
│       ├── context-loader/      # コンテキスト読み込みスキル
│       └── design-tracker/      # 設計トラッキングスキル
│
└── scripts/
    └── update.sh               # テンプレート更新スクリプト
```

### Codex 連携の安定化

- Codex への依頼は `@.claude/docs/CODEX_HANDOFF_PLAYBOOK.md` のテンプレートで標準化する
- `.claude/rules/codex-delegation.md` が委譲ポリシー（計画は Claude 主導、Codex は実装と設計相談）と例外条件を定義。モデルレーンは `.claude/rules/model-routing.md` を参照
- `.codex/config.toml` は `approval_policy = "never"` を採用し、非対話フローでのブロッキングを防止

## ワークフロー

メインワークフローは2つのスキルを順に実行します。

```
/feature <機能>      計画: モード判定 → 理解 → 調査・設計 → 計画
    ↓ ユーザー承認後（COMPLEX ルート）
/team-execute        Phase 1: 並列実装 → Phase 2: 並列レビュー（Agent Teams）
```

1. **モード判定**: existing（Codex 直接相談での設計）か greenfield（Agent Teams による調査・設計）か
2. **Opus サブエージェント**がコードベースを分析（1M コンテキスト）＋ **Claude** がユーザーと要件をすり合わせ
3. existing モード: **Codex** が設計・計画・検証を提案し、**Claude** が最終決定。greenfield モード: **Agent Teams** — Researcher（Opus）と Architect（Codex）が並列で作業
4. **Claude** が調査と設計を統合し、計画をユーザーに提示
5. 承認後、`/team-execute` がモジュール単位の並列実装、続けてセキュリティ・品質・テストの並列レビューを実行（`--review-only` で実装をスキップ）

## スキル

### コアワークフロー

#### `/feature` — 機能の計画・実装（統合版）

機能開発の単一エントリーポイント。2つのモードを持ちます（旧 `/add-feature` と `/start-feature` の統合）。

```
/feature ユーザープロフィール編集機能
```

**モード：**
- **existing**（旧 `/add-feature`）— 既存コードベースへの機能追加。Claude 主導の計画のもと、Opus サブエージェント + Codex がスコープ・影響を分析し、Codex がアーキテクチャ・計画・検証を提案、Claude が最終決定
- **greenfield**（旧 `/start-feature`）— 外部調査が必要な大型・新規機能。Opus サブエージェントのコードベース分析の後、Agent Teams（Researcher [Opus] + Architect [Codex]）が並列で調査・設計

**共通の複雑度ルーティング：**
- SIMPLE（1〜3ファイル、50 LOC 未満）→ Codex が直接実装
- MODERATE（3〜5ファイル）→ Codex 実装 + `/team-execute --review-only`
- COMPLEX（5ファイル以上）→ `/team-execute`

#### `/team-execute` — 並列実装＋レビュー（統合版）

2フェーズの Agent Teams 実行（旧 `/team-implement` と `/team-review` の統合）。`/feature` で承認された計画に基づいて実行します。

```
/team-execute                 # Phase 1 IMPLEMENT → Phase 2 REVIEW
/team-execute --review-only   # Phase 1 をスキップし、既存の変更をレビュー
```

**Phase 1 IMPLEMENT：**
- モジュール／レイヤーごとに Teammate を起動し、ファイル所有権を分離
- 共有タスクリストで依存関係を管理し、自律的に協調
- 各 Teammate は完了時に `.claude/logs/agent-teams/` へ作業ログを記録

**Phase 2 REVIEW（レビュアー構成）：**
- **Security Reviewer**（Opus）— セキュリティ脆弱性の検出
- **Quality Reviewer**（Sonnet）— コード品質・パターン準拠の確認（Codex を活用）
- **Test Reviewer**（Sonnet）— テストカバレッジ・品質の検証

#### `/spike` — 技術調査・実現可能性検証

タイムボックス付きの技術調査で、全フェーズで Codex に相談します。**意思決定文書**（go/no-go 推奨付き）を作成します。実装計画ではなく、意思決定の材料を提供します。

```
/spike WebSocket と SSE どちらを採用すべき？
```

**ワークフロー：**
1. **Claude + Codex** → 調査課題の設定と制約の定義
2. **Agent Teams** → Researcher（Opus による外部調査）と Feasibility Analyst（Codex による深い分析）が並列で調査
3. **Codex** → go/no-go 推奨に統合し、調査レポートを作成

> GO 判断の後は `/feature` で実装に進みます

### 開発

#### `/plan` — 実装計画

要件を具体的なステップに分解します。

```
/plan API エンドポイントの追加
```

**出力：**
- 実装ステップ（ファイル・変更内容・検証方法）
- 依存関係とリスク
- 検証基準

#### `/tdd` — テスト駆動開発

Red-Green-Refactor サイクルで実装します。

```
/tdd ユーザー登録機能
```

**ワークフロー：**
1. テストケースの設計
2. 失敗するテストを書く（Red）
3. 最小限の実装（Green）
4. リファクタリング（Refactor）

#### `/simplify` — コードリファクタリング

コードを簡素化し、可読性を向上させます。

#### `/troubleshoot` — エラー診断・修正計画

Codex を中心としたマルチエージェント協調でエラーを診断し、修正計画を作成します。

```
/troubleshoot TypeError: cannot unpack non-iterable NoneType object
```

**ワークフロー：**
1. **Opus サブエージェント + Codex** → エラーの再現とコンテキスト収集
2. **Agent Teams** → Root Cause Analyst（Codex 主導）と Impact Investigator（Opus + Codex）が並列で診断
3. **Claude + Codex** → 修正計画の統合とユーザー承認

### エージェント委譲

#### `/codex-system` — Codex CLI 統合

設計相談・デバッグ・トレードオフ分析・複雑な実装に使います。

**トリガー例：**
- 「どう設計すべき？」「どう実装すべき？」
- 「なぜ動かない？」「エラーが出る」
- 「どちらがいい？」「比較して」

### ドキュメント

#### `/design-tracker` — 設計判断のトラッキング

会話中の設計判断を検出し、`.claude/docs/DESIGN.md` の該当セクション（機能要件 / 非機能要件 / アーキテクチャ / 技術選定 / 制約 / Key Decisions）を構造的に更新します。自動的に起動するほか、明示的な依頼（「これを記録して」「DESIGN を更新して」）でも動きます。

#### `/research-lib` — ライブラリ調査

ライブラリを調査し、`.claude/docs/libraries/` に包括的なドキュメントを生成します。

```
/research-lib httpx
```

#### `/update-lib-docs` — ライブラリドキュメントの更新

`.claude/docs/libraries/` の既存ドキュメントを最新情報に更新します。

### セッション管理

#### `/checkpointing` — セッション永続化

セッションの全アクティビティ（ユーザーの依頼、git 履歴、CLI 相談、Agent Teams の活動、設計判断）をチェックポイントに記録します。冒頭には5セクションのサマリ（何をしたのか / どういうやり取りをユーザーと行ったのか / どうやったのか / 途中でどういう課題が起こったのか / 将来のアクション）が付きます。続けてローリングの `PROGRESS.md`（直近5チェックポイントの要約）を再生成し、`.claude/docs/DESIGN.md` の更新要否を確認（必要なら `/design-tracker` を起動）、最後に組み込みの**コンパクトフェーズ**が CLAUDE.md Zone C の古い作業ブロックを整理し、会話をコンパクトにします。再利用可能なスキルパターンの発見も行います。

```bash
/checkpointing                    # フル記録 + パターン発見
/checkpointing --since "2026-02-08"  # 指定日以降のみ
/checkpointing --compact-only    # コンパクトフェーズのみ実行（旧 /context-refresh）
```

#### `/init` — プロジェクト初期化

プロジェクト構造を分析し、技術スタック・コマンド・設定を自動検出します。`.claude/docs/DESIGN.md`（要件定義書 — マクロな要件・設計）と AGENTS.md を作成し、CLAUDE.md Zone B に DESIGN.md への薄いポインタを書き込みます。

#### `/catchup` — オンボーディングガイド

リポジトリをスキャン（git 履歴、CLAUDE.md/AGENTS.md、プロジェクトルール、スキルカタログ、DESIGN.md、調査・ライブラリノート、チェックポイント、Agent Teams ログ）し、リポジトリルートに `GUIDE.md` を生成します。新規・復帰のコントリビューターが過去の作業を理解し、素早く再開できるようにします。

```bash
/catchup
```

## 開発

### テンプレート更新

テンプレートの更新をローカルプロジェクトに安全に適用します。

```bash
# 最新バージョンへ更新
./scripts/update.sh

# 特定バージョンへ更新
./scripts/update.sh v0.2.0

# 確認プロンプトをスキップ
./scripts/update.sh --yes
```

**動作の仕組み：**
- `CLAUDE.md` は2つのマーカーで区切られた3ゾーン構成です：
  - **Zone A**（`@orchestra:template-boundary` より上）— オーケストラのコンセプトとテンプレート基盤。更新時に完全置換
  - **Zone B**（2つのマーカーの間）— リポジトリのアイデンティティ。`/init` が管理し、更新後も保持
  - **Zone C**（`@orchestra:repo-boundary` より下）— 作業状態（機能・セッションノート）。更新後も保持
- 旧レイアウト（`@orchestra:local-boundary`）のプロジェクトは初回実行時に自動移行されます：旧マーカーより下の内容は Zone C になり、Zone B はプレースホルダーにリセットされ `/init` で再生成できます
- skills / hooks / rules / agents は完全同期されます
- `.claude/docs/research/` などのローカルデータは保持されます
- `.claude/settings.json` は差分表示のみ（手動マージが必要）

### 技術スタック

| ツール | 用途 |
|--------|------|
| **uv** | パッケージ管理（pip は使用禁止） |
| **ruff** | リント・フォーマット |
| **ty** | 型チェック |
| **pytest** | テスト |
| **poethepoet** | タスクランナー |

### コマンド

```bash
# 依存関係
uv add <package>           # パッケージ追加
uv add --dev <package>     # 開発用依存の追加
uv sync                    # 依存関係の同期

# 品質チェック
poe lint                   # ruff check + format
poe typecheck              # ty
poe test                   # pytest
poe all                    # 全チェック実行

# 直接実行
uv run pytest -v
uv run ruff check .
```

## Hooks

自動化フックが適切なタイミングでエージェント連携と品質チェックを実行します。

| フック | トリガー | 動作 |
|--------|----------|------|
| `agent-router.py` | ユーザー入力 | Codex / Opus サブエージェント / Sonnet レビューへのルーティングを提案 |
| `lint-on-save.py` | ファイル保存 | lint を自動実行 |
| `check-codex-before-write.py` | ファイル書き込み前 | 高難度設計での Codex 相談を提案 |
| `check-codex-after-plan.py` | Task 実行後 | 計画・設計タスク後の Codex 設計相談を提案 |
| `error-to-codex.py` | Bash エラー検出 | codex-debugger サブエージェントを提案 |
| `post-test-analysis.py` | テスト・ビルド失敗 | Codex によるデバッグ分析を提案 |
| `post-implementation-review.py` | 大規模実装後 | レビューを提案（Sonnet デフォルト、高リスクは Opus + `/codex:review`） |
| `log-cli-tools.py` | Codex 実行 | 入出力ログを記録 |

## 言語ルール

- **コード・思考・推論**: 英語
- **ユーザーへの応答**: 日本語
- **技術ドキュメント**: 英語（例外: `docs/manual/` 配下は日本語）
- **README など**: 日本語可
