# rails-infra-learning

Ruby on Rails のインフラ周りを **ハンズオン中心** で学ぶリポジトリです。

「Rails が裏でやっている『よしなに』」を、実際に手を動かして観察しながら理解していきます。

---

## このリポジトリは何か

普段 Rails を書いていると、こういう疑問が湧いてきます。

- `User.find(1)` を書いたとき、裏で何が起きているのか
- 「コネクションプール」という言葉は聞くけど、実体は何なのか
- 「DB 接続が枯渇した」というエラーは、何がどう枯渇しているのか
- TCP やソケット、ファイルディスクリプタといった概念は Rails と何の関係があるのか

このリポジトリでは、こういった疑問を **コードを動かして数字や挙動で確認する** ことで埋めていきます。

---

## ディレクトリ構成

```
rails-infra-learning/
├── README.md                      ← このファイル
├── LICENSE
├── .gitignore
│
├── docs/                          ← 読むもの (学習メモ・基礎知識)
│   ├── aws_network_basics.md      ← AWS とネットワーク基礎
│   └── web_server_basics.md       ← Web サーバー / HTTP / REST の基礎
│
├── handson/                       ← 動かすもの (実機ハンズオン教材)
│   └── 01-active-record-pool/     ← ActiveRecord のコネクションプール観察
│       ├── README.md              ← 学習プラン (Step 0-7)
│       ├── CHEATSHEET.md          ← lsof / ss / tcpdump 等のコマンド集
│       ├── Gemfile
│       ├── docker-compose.yml     ← MySQL コンテナの起動設定
│       └── scripts/               ← 各 Step の Ruby スクリプト
│
└── future/                        ← 次に学ぶ予定のトピック
    └── README.md
```

---

## どこから読めばいいか

**初めて訪れた人** はここから:

1. このリポジトリ全体の方針を知る → このファイル (上記)
2. ActiveRecord ハンズオンを試す → [`handson/01-active-record-pool/README.md`](./handson/01-active-record-pool/README.md)
3. もっと知識を補強したい → [`docs/`](./docs/) の各ファイル

**学習者本人 (リポジトリのオーナー)** はここから:

1. 次に何をやるか決める → [`future/README.md`](./future/README.md)

---

## ハンズオン一覧

| # | タイトル | テーマ | 状態 |
|---|---------|--------|------|
| 01 | [active-record-pool](./handson/01-active-record-pool/) | ActiveRecord のコネクションプールを TCP / OS / DB の3視点から観察する | 教材作成済 / 実行はこれから |

今後、PgBouncer や TLS、Multiple Databases などのトピックを `02-`, `03-` と追加していく予定です。
予定は [`future/README.md`](./future/README.md) を参照してください。

---

## 動作環境

ハンズオンによって異なります。各ハンズオンの README に記載していますが、共通で必要なものは以下です。

- **macOS / Linux / WSL** いずれか
- **Ruby 3.0 以上**
- **Bundler**
- **Docker** (DB を立てるため)

OS 固有のコマンド (例: `ss` は Linux のみ、`lsof` は両方など) はハンズオン内で都度補足しています。

---

## このリポジトリの方針

- **手を動かす学習** : 読むだけで終わらせず、実機で数字が動くのを目で見ることを重視する
- **複数レイヤーを同時に見る** : Rails 側 / OS 側 / ネットワーク側 / DB 側を別々のターミナルで観察するスタイル
- **比喩と図で直感を育てる** : 抽象論だけでなく、電話の比喩などで腑に落とすことを意識
- **公開しているけど学習者本人のためのもの** : 親切な解説を心がけているが、研修教材としての完成度は保証しない

役に立ちそうなら自由に使ってください。間違いを見つけたら Issue / PR 大歓迎です。

---

## ライセンス

MIT License — 詳細は [LICENSE](./LICENSE) を参照してください。
