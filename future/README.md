# 次に学びたいトピック

このリポジトリで今後扱っていく予定のトピックを集めたメモです。
着手したらハンズオン化して `handson/` 以下に移していきます。

---

## 着手予定 (近いうちに)

### PgBouncer / RDS Proxy
- アプリ側プールと DB の間に挟む追加プール層
- なぜ必要か (アプリプールだけでは足りない場面)
- どこにどう挟むのか
- ハンズオンとして PgBouncer をローカルで立てて挙動を観察

### TLS / SSL
- 現状の `06_tcpdump_handshake.rb` で見えた平文通信を暗号化する
- TLS ハンドシェイクの中身を tcpdump で観察
- MySQL に TLS を有効化して、再度パケットを見比べる

### Multiple Databases (Rails 6+)
- `connects_to writing/reading` の使い分け
- Database Selector ミドルウェア
- レプリカ遅延対策

---

## 周辺レイヤーの掘り下げ

### `strace` / `dtruss`
- システムコールレベルで `connect()` `read()` `write()` を追う
- Ruby の1行が、何回・どんなシステムコールを呼んでいるかを見る

### Wireshark
- `tcpdump` の pcap ファイルを GUI で解析
- MySQL プロトコルパーサーで構造化されたパケットを見る

### Linux カーネルの TCP 実装
- `/proc/sys/net/ipv4/tcp_*` の各種パラメータ
- TIME_WAIT 関連のチューニング

---

## 元の授業メモから未消化のトピック

最初の出発点となった授業メモから、まだ深掘りしていないもの。

- **KVS (DynamoDB)** の使い分け、書き込みに強い理由
- **S3** の static 配信、Route53 / DNS との関係
- **OpenSearch** の検索エンジンとしての位置づけ
- **HTTP / HTTPS** のハンドシェイク詳細
- **file:// プロトコル** や **FTP** の仕組み

---

## 着手したトピック (アーカイブ)

着手・完了したものは以下に移していきます。

- (なし)
