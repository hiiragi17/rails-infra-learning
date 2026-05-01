# ActiveRecord × ネットワーク観察ハンズオン (v2)

Railsの「よしなに」の正体を、**Rails側 と OS/ネットワーク側の両方から**観察する勉強プランです。

v1 (`01〜04`) はアプリ層だけの観察、v2 (`05〜07`) で**OS層・ネットワーク層も同時に見る**ステップを追加しました。

---

## ゴール

このハンズオンが終わると、以下が説明できるようになります。

**v1 部分 (アプリ層)**:
- ActiveRecord の ConnectionPool が「何本のconnを、いつ、誰に貸しているか」を覗ける
- スレッド競合で checkout 待ちが発生する様子を再現できる
- トランザクションが「同一conn保証」で成り立っていることを実証できる
- プール枯渇 (`ConnectionTimeoutError`) を意図的に起こせる

**v2 部分 (OS/ネットワーク層)**:
- `pool.stat` の `connections` 数が、OS の TCP ソケット数と一致することを確認できる
- コネクション = ファイルディスクリプタ であることを実演できる
- TCP の 3way handshake と MySQL認証パケットを `tcpdump` で目視できる
- `ulimit -n` の上限に当てて、fd 枯渇エラーを再現できる
- プロダクション障害時の切り分け (アプリ側か OS側か DB側か) ができる

---

## 前提知識: そもそも「コネクション」「conn」って何?

ハンズオンに入る前に、ここを腹落ちさせておくと全部スッキリします。

### コネクションを電話に例えると

DBコネクションのイメージは、**電話の通話**にすごく似ています。

```
あなた (Railsアプリ)              相手 (MySQLサーバー)
   ┌─────────┐                     ┌─────────┐
   │         │                     │         │
   │  📞 ━━━━━━━━━━━━━━━━━━━━━━━━━━━ 📞  │
   │         │  通話中 (ESTABLISHED)│         │
   └─────────┘                     └─────────┘
```

電話で考えると:

| 電話 | DBコネクション |
|------|---------------|
| 番号を回す | `connect()` を呼ぶ |
| 相手が出る | サーバーが接続を受け入れる |
| 「もしもし、田中です」 (本人確認) | ユーザー名・パスワードで認証 |
| 通話中 | ESTABLISHED 状態 |
| 「〜について教えて」 | SQLクエリを送る |
| 相手の返事 | 結果が返ってくる |
| 切る | `close()` を呼ぶ |

そして大事なのが、**通話を切らずに何度も会話できる**こと。1回の通話で「Aを教えて」「ありがとう、次はBを教えて」と続けられますよね。これがコネクションの「使い回し」です。

### なぜわざわざ「貼っておく」のか

毎回切ってかけ直すのは面倒、という話です。

```
パターン1: 毎回切る (悪い例)
クエリ① → 番号回す → 認証 → SQL → 結果 → 切る
クエリ② → 番号回す → 認証 → SQL → 結果 → 切る
クエリ③ → 番号回す → 認証 → SQL → 結果 → 切る
```

「番号回す + 認証」が毎回かかる。これが TCP の 3way handshake と MySQL認証で、実は**結構時間がかかる**(数十ミリ秒)。

```
パターン2: 繋ぎっぱなし (良い例)
クエリ① → SQL → 結果
クエリ② → SQL → 結果
クエリ③ → SQL → 結果
... (最後まで繋いだまま)
```

最初に1回だけ「番号回す + 認証」して、あとは使い回す。**これがコネクション**です。

### では「コネクションプール」とは

電話を**何本か並べて持っておく**イメージです。

```
Railsプロセスの中:
┌─────────────────────────────────┐
│  ConnectionPool (5本まで)       │
│                                 │
│   📞 conn1  (使用中)            │ ← Aさん(スレッド)が使ってる
│   📞 conn2  (使用中)            │ ← Bさんが使ってる
│   📞 conn3  (空いてる)          │
│   📞 conn4  (空いてる)          │
│   📞 conn5  (まだ作ってない)    │
│                                 │
└─────────────────────────────────┘
```

なぜ複数本必要かというと、**Railsは複数のリクエストを同時にさばく**から。

電話1本だけだと、Aさんが使っている間 Bさんは待たないといけない。Webサービスでこれをやると遅くなるので、何本か並べておいて**「空いてる電話を借りて、使い終わったら返す」**という仕組みにしてあります。これが「貸し借り」(checkout / checkin)です。

### 「conn」 = 1本の電話 = 1本のソケット

`conn` は `connection` (コネクション) の略です。「DBコネクション」「データベース接続」と同じものを指します。

`pool.stat` で見えるあの数字は、すべて「電話の本数」だと思って読み直すと分かりやすいです:

```ruby
{size: 5, connections: 3, busy: 2, idle: 1, waiting: 0}
```

| キー | 意味 (電話の例え) |
|------|-----------------|
| `size: 5` | 用意できる電話は最大5本 |
| `connections: 3` | 今までに実際に**繋いだ**電話の本数 (3本) |
| `busy: 2` | そのうち**今使われている**のが2本 |
| `idle: 1` | 繋がっているけど**空いている**のが1本 |
| `waiting: 0` | 「電話空いたら使わせて」と**待っている人**の数 |

電話は使うときに初めて繋ぐ(=遅延生成)ので、起動直後は `connections: 0` (まだ1本も繋いでいない)。最初のクエリで初めて1本繋がって `connections: 1` になります。

### OS から見ると「TCPソケット」

ここまで「電話」という比喩で話しましたが、実体は何かというと **TCPソケット** です。

OSにとってコネクションは:
- ネットワーク越しに相手と繋がっている**通信路**
- ファイルディスクリプタ(fd)を1つ消費する
- `lsof` や `ss` コマンドで見える

つまり、こういう対応関係になります:

```
Rails視点:    "コネクション" "conn"
                    ↓
OS視点:       TCPソケット (fd 1個)
                    ↓
ネットワーク: 3306番ポートへのTCP接続 (ESTABLISHED状態)
                    ↓
DB視点:       PROCESSLIST に1行
```

**全部同じものを別の角度から見ているだけ**です。Step 5 でこの3つの視点を同時に観察するのは、「コネクション」という1つの実体が、レイヤーごとに違う名前で呼ばれているのを目で確認する作業です。

### まとめ

- `conn` = `connection` の略
- DBコネクション = アプリと DB の間の**繋ぎっぱなしの通信路**
- 電話の通話みたいなもの。最初の「番号回す + 認証」が重いから、繋いだまま使い回す
- ConnectionPool = その電話を**何本か並べて持っておく仕組み**
- 1本の conn = OS的には1個のTCPソケット = fd 1個

ここが腑に落ちたら、ハンズオンの観察結果が「ああ、電話が今こうなっているんだな」と素直に読めるようになります。

---

## 前提環境

- macOS / Linux / WSL いずれか
- Ruby 3.0 以上
- Bundler
- Docker (Step 3 以降で必要)
- `lsof`, `ss` (Linux) または `netstat` (macOS)
- `tcpdump` (Step 6 で sudo 権限必要)
- mysql クライアント (Docker exec 経由でも OK)

---

## 全体の流れ (所要 3〜4時間)

| Step | 所要 | 何を学ぶ | レイヤー |
|------|------|---------|---------|
| 0  | 10分 | 環境構築 | - |
| 1  | 20分 | `pool.stat` でプールを覗く | アプリ |
| 2  | 30分 | スレッド競合と checkout 待ち | アプリ |
| 3  | 30分 | DB側から見たconn (processlist) | アプリ + DB |
| 4  | 20分 | 発展課題 (同一conn保証など) | アプリ |
| **5** | **30分** | **`pool.stat` と OS のソケット数を一致させる** | **アプリ + OS** |
| **6** | **30分** | **tcpdump で TCP/MySQLパケットを目視** | **ネットワーク** |
| **7** | **30分** | **fd / ulimit で OS の上限に当てる** | **OS カーネル** |

各 Step は独立しているので、興味あるところから始めて OK です。

---

## Step 0〜4 (アプリ層の観察)

```bash
# 環境構築
bundle install

# Step 1: プールの状態を覗く
bundle exec ruby scripts/01_pool_stat.rb

# Step 2: スレッド競合
bundle exec ruby scripts/02_checkout_race.rb
bundle exec ruby scripts/02b_leak.rb

# Step 3: DB側のprocesslistと突き合わせ (要MySQL)
cp .env.example .env   # 初回のみ: パスワードなどを定義した .env を作成
docker compose up -d   # docker-compose.yml で MySQL を起動
bundle exec ruby scripts/03_db_processlist.rb

# Step 4: 発展課題
bundle exec ruby scripts/04a_same_connection.rb
bundle exec ruby scripts/04b_transaction_leak.rb
bundle exec ruby scripts/04c_notifications.rb
```

各スクリプトの中身に詳しいコメントがあります。

---

## Step 5: pool.stat と OS のソケット数を突き合わせる ⭐

**狙い**: 「Railsが言うコネクション数」と「OSが実際に開いているTCPソケット数」が一致することを目で確認する。

### 手順

ターミナル1 (Rails):
```bash
bundle exec ruby scripts/05_network_observe.rb
```

スクリプトが PID を表示したら、**Enter を押す前に**ターミナル2を開く。

ターミナル2 (OS側):
```bash
# Linux
ss -tnp | grep <PID>

# macOS
lsof -p <PID> -a -i TCP
```

ターミナル3 (DB側):
```bash
docker exec -it ar-mysql mysql -uroot -ppass -e "SHOW PROCESSLIST"
```

スクリプトの各段階 (① 起動直後 → ② 1回クエリ → ③ 並行クエリ → ④ 終了後 → ⑤ disconnect) で、**3つのターミナルを見比べる**。

### 期待される結果

| 段階 | Rails側 (`pool.stat`) | OS側 (`ss`/`lsof`) | DB側 (`PROCESSLIST`) |
|------|----------------------|-------------------|---------------------|
| ① 起動直後 | connections: 0 | 接続なし | 接続なし |
| ② 1回クエリ | connections: 1 | ESTABLISHED 1本 | Sleep 1本 |
| ③ 並行3スレッド | busy: 3 | ESTABLISHED 3本 | Query 3本 |
| ④ 終了後 | busy: 0, idle: 3 | ESTABLISHED 3本 | Sleep 3本 |
| ⑤ disconnect | connections: 0 | TIME_WAIT または消える | 接続なし |

**ここで分かること**:
- ④で busy=0 なのに OS側は ESTABLISHED が残る → これが「使い回し」の正体
- ⑤で TIME_WAIT になる → TCPの仕様で、すぐには消えない (約60秒)

### 学習チェックポイント

- [ ] Rails が「conn を貼る」と言っているのは TCP ソケットを開くこと、と説明できる
- [ ] アイドル接続が DB 側にも OS 側にも残る理由が分かった
- [ ] TIME_WAIT 状態を実際に観察できた

---

## Step 6: tcpdump で TCP/MySQL パケットを目視 ⭐

**狙い**: Ruby の1行 (`ActiveRecord::Base.connection.execute("SELECT 1")`) が、実際にどんなバイト列としてネットワークに流れるかを見る。

### 手順

ターミナル1 (パケット捕捉):
```bash
# Linux
sudo tcpdump -i lo -nn 'port 3306' -A

# macOS
sudo tcpdump -i lo0 -nn 'port 3306' -A
```

ターミナル2 (Rails):
```bash
bundle exec ruby scripts/06_tcpdump_handshake.rb
```

### tcpdump の出力で見えるもの

```
... Flags [S], seq 0, ...                       ← SYN
... Flags [S.], seq 0, ack 1, ...               ← SYN-ACK
... Flags [.], ack 1, ...                       ← ACK (3way handshake完了)
... Flags [P.], length 78                       ← MySQL Greeting
        ........8.0.32-MySQL Community...       ← サーバーのバージョン文字列が見える
... Flags [P.], length 70                       ← クライアント認証
        ...root.....playground...               ← ユーザー名が平文で見える
... Flags [P.], length 13                       ← クエリ送信
        .....SELECT 1                            ← SQL文が丸見え
... Flags [F.], ...                             ← FIN (切断開始)
```

### 観察ポイント

- **SYN → SYN-ACK → ACK** の3パケットで接続成立 (3way handshake)
- **MySQL のバージョン番号がサーバーから平文で返る** (Greeting)
- **ユーザー名は平文、パスワードはハッシュ化されて送信**
- **クエリ本文も結果も平文** (TLS未使用時)
- だから本番では SSL/TLS が必須

### 発展実験

```bash
# pcapファイルに保存して Wireshark で開く
sudo tcpdump -i lo -nn 'port 3306' -w /tmp/mysql.pcap
wireshark /tmp/mysql.pcap
# → Wireshark には MySQL プロトコルパーサーがあるので、
#    "MySQL Login Request" "Query" などが構造化されて見える
```

### 学習チェックポイント

- [ ] TCP の 3way handshake を実際に目視した
- [ ] MySQL プロトコルが平文であることを確認した (TLS の必要性を理解)
- [ ] パケットレベルで通信を覗くスキルを習得した

---

## Step 7: fd と ulimit で OS の上限に当てる ⭐

**狙い**: コネクション = ファイルディスクリプタ であることを実演し、`Too many open files` エラーを意図的に再現する。

### 手順

ターミナル1 (Rails):
```bash
bundle exec ruby scripts/07_fd_limit.rb
```

ターミナル2 (OS監視):
```bash
# Linux
watch -n 0.5 'ls /proc/<PID>/fd | wc -l'

# macOS
watch -n 0.5 'lsof -p <PID> | wc -l'
```

### 期待される結果

```
checkout 1本: pool.connections=1, OS fd数=15
checkout 5本: pool.connections=5, OS fd数=19
checkout 10本: pool.connections=10, OS fd数=24
checkout 30本: pool.connections=30, OS fd数=44
checkout 50本: pool.connections=50, OS fd数=64
```

**fd数 = 起動直後のfd数 + コネクション数** になっているはず。

### 発展実験: fd 枯渇を意図的に起こす

```bash
# シェルの fd 上限を低く設定
ulimit -n 30

# 同じスクリプトを実行
bundle exec ruby scripts/07_fd_limit.rb
# → 途中で 'Too many open files' エラーが出る
```

これがプロダクションでよくある「謎の接続エラー」の正体の一つ。

### よくあるプロダクション設定

| 環境 | 設定方法 |
|------|---------|
| Linux 一般 | `/etc/security/limits.conf` で `* soft nofile 65536` |
| systemd | unit ファイルに `LimitNOFILE=65536` |
| Docker | `docker run --ulimit nofile=65536:65536 ...` |
| Kubernetes | コンテナイメージ側で設定 |

### 学習チェックポイント

- [ ] コネクション1本 = fd 1個 を実演で確認した
- [ ] `Too many open files` エラーを再現できた
- [ ] プロダクションで ulimit を上げる必要性が理解できた

---

## ファイル一覧

```
01-active-record-pool/
├── README.md                    ← このファイル
├── CHEATSHEET.md                ← ⭐ ネットワーク観察コマンド集
├── Gemfile
├── docker-compose.yml           ← MySQL コンテナの起動設定
└── scripts/
    ├── 01_pool_stat.rb          ← Step 1
    ├── 02_checkout_race.rb      ← Step 2
    ├── 02b_leak.rb              ← Step 2 発展
    ├── 03_db_processlist.rb     ← Step 3
    ├── 04a_same_connection.rb   ← Step 4 課題A
    ├── 04b_transaction_leak.rb  ← Step 4 課題B
    ├── 04c_notifications.rb     ← Step 4 課題C
    ├── 05_network_observe.rb    ← Step 5
    ├── 06_tcpdump_handshake.rb  ← Step 6
    └── 07_fd_limit.rb           ← Step 7
```

スクリプト実行時は、このディレクトリ (`01-active-record-pool/`) から `bundle exec ruby scripts/01_pool_stat.rb` のように `scripts/` 経由で叩いてください。

---

## 学習プラン (推奨順序)

### 集中プラン (3〜4時間, 1日でやるなら)

1. **Step 0 → 1 → 2** (1時間): まずアプリ層で「プールとは何か」を掴む
2. **Step 3 → 5** (1時間): DB側 + OS側に視点を広げる
3. **Step 6** (30分): パケットを直接見る体験
4. **Step 7** (30分): fd の話で OS の上限に触れる

### 分割プラン (週末数回でじっくり)

- 1日目: Step 0-2 (アプリ層の基礎)
- 2日目: Step 3-4 (DB側 + 課題)
- 3日目: Step 5 + CHEATSHEET 読み込み
- 4日目: Step 6-7 (ネットワーク・OS層)

### 「いつでも見返す」用

- **`CHEATSHEET.md`** は手元に残しておくと、実務で「なんかDB接続おかしい」となった時の最初の道具箱になります

---

## 次のステップ

これが終わったら、以下に進むと自然に深まります。

### 周辺技術への展開
- **PgBouncer / RDS Proxy**: アプリ側プールと DB の間に挟む追加プール層
- **Connection multiplexing**: 1ソケットで複数のクエリを多重化する仕組み
- **TLS/SSL**: Step 6 で見た平文通信の暗号化

### 周辺レイヤーの掘り下げ
- **`strace`/`dtruss`**: システムコールレベルで `connect()` `read()` `write()` を追う
- **Wireshark**: tcpdump の pcap ファイルを GUI で解析
- **Linux カーネルの TCP実装**: `/proc/sys/net/ipv4/tcp_*` の各種パラメータ

### Rails 固有の深掘り
- **Multiple Databases**: writing/reading の振り分け
- **Database Selector ミドルウェア**: レプリカ遅延対策
- **Active Record のソースコード**: `bundle open activerecord`
