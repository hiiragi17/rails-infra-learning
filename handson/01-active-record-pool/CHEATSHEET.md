# ネットワーク観察コマンド チートシート

ハンズオン中に「Rails側で何かが起きた瞬間」に隣で叩くコマンド集。
OSによって微妙にコマンドが違うので、両方併記。

---

## 1. プロセスのソケット一覧を見る

何を確認したいか: **「このプロセスは今、何個のTCP接続を持っているか」**

### Linux

```bash
# プロセスIDを指定して、TCPソケットだけ抽出
ss -tnp | grep <PID>

# より詳しく
ss -tnp 'state established'

# 自分のプロセスで3306に繋いでいるものだけ
ss -tn 'dport = :3306'
```

### macOS

```bash
# Linuxの ss はないので lsof で代替
lsof -p <PID> -a -i TCP

# ESTABLISHEDのみ
lsof -p <PID> -a -i TCP -s TCP:ESTABLISHED

# 3306 への接続を持つプロセス全部
lsof -i :3306
```

### 両OS共通 (古いがどこでも動く)

```bash
netstat -an | grep 3306
netstat -an | grep ESTABLISHED
```

---

## 2. fd (ファイルディスクリプタ) の状態

何を確認したいか: **「このプロセスは何個のfdを開いているか」「上限はいくつか」**

### Linux

```bash
# 現在開いているfd一覧
ls -la /proc/<PID>/fd/

# 個数だけ
ls /proc/<PID>/fd/ | wc -l

# プロセス固有のリソース上限
cat /proc/<PID>/limits | grep "open files"

# 自分のシェルの上限
ulimit -n              # ソフトリミット
ulimit -Hn             # ハードリミット
```

### macOS

```bash
# /proc が無いので lsof で代替
lsof -p <PID> | wc -l

# シェルの上限
ulimit -n
launchctl limit maxfiles    # システム全体の上限
```

---

## 3. パケットを直接見る (tcpdump)

何を確認したいか: **「実際にどんなTCPパケットが流れているか」**

```bash
# Linux: ローカルループバック上の3306宛/発のパケット
sudo tcpdump -i lo -nn 'port 3306' -A

# macOS: インターフェース名が lo0
sudo tcpdump -i lo0 -nn 'port 3306' -A

# より詳しく (バイナリ含む)
sudo tcpdump -i lo -nn 'port 3306' -vvv -X

# pcapファイルに保存して後で Wireshark で見る
sudo tcpdump -i lo -nn 'port 3306' -w /tmp/mysql.pcap
# → 後で wireshark /tmp/mysql.pcap
```

オプション説明:
- `-i lo`: 監視するインターフェース (loopback)
- `-nn`: 名前解決しない (高速)
- `'port 3306'`: フィルタ式
- `-A`: ASCII で表示 (SQL文が読める)
- `-X`: hex + ASCII
- `-vvv`: 詳細表示

---

## 4. TCP状態の遷移を見る

何を確認したいか: **「接続がESTABLISHEDになったか、TIME_WAITで残っているか」**

### Linux

```bash
# 状態別に集計
ss -tan | awk '{print $1}' | sort | uniq -c

# TIME_WAITの数
ss -tan state time-wait | wc -l

# 全状態を見る
ss -tan
```

### macOS

```bash
netstat -an -p tcp | awk '{print $6}' | sort | uniq -c

# TIME_WAITだけ
netstat -an -p tcp | grep TIME_WAIT
```

TCP状態の意味:

| 状態 | 意味 |
|------|------|
| LISTEN | サーバー側で接続待ち |
| SYN_SENT | クライアントが接続要求中 |
| SYN_RECV | サーバーが応答中 |
| ESTABLISHED | 接続完了。実際にデータが流れる状態 |
| FIN_WAIT_1/2 | 切断要求中 |
| CLOSE_WAIT | 相手は切ったがこっちが close() を呼んでない (リーク兆候) |
| TIME_WAIT | 切断完了。約60秒残ってから消える |

**CLOSE_WAITが大量に出ていたらアプリのバグ** (close忘れ)。

---

## 5. DB側からのコネクション確認

### MySQL / Aurora

```sql
-- 全接続を見る
SHOW PROCESSLIST;

-- 詳しく(state, queryまで)
SELECT id, user, host, db, command, time, state, info
FROM information_schema.processlist;

-- 接続数の上限と現在値
SHOW VARIABLES LIKE 'max_connections';
SHOW STATUS LIKE 'Threads_connected';
SHOW STATUS LIKE 'Threads_running';

-- ホスト別の接続数
SELECT host, COUNT(*) FROM information_schema.processlist GROUP BY host;
```

### PostgreSQL

```sql
SELECT pid, application_name, client_addr, state, query
FROM pg_stat_activity;

SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;

-- ステートごとに集計
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
```

---

## 6. 観察を組み合わせる「セット技」

### セット1: Rails が conn を貼る瞬間を3視点で見る

ターミナル1 (Rails):
```bash
bundle exec ruby 06_tcpdump_handshake.rb
```

ターミナル2 (パケット):
```bash
sudo tcpdump -i lo -nn 'port 3306' -A
```

ターミナル3 (DB側):
```bash
watch -n 0.5 'docker exec ar-mysql mysql -uroot -ppass -e "SHOW PROCESSLIST"'
```

→ Rubyの1行が、TCPパケットとして飛び、DB側にプロセスとして現れる、を一望できる。

### セット2: プール枯渇とfd枯渇を区別する

ターミナル1: `02_checkout_race.rb` でプール枯渇 (アプリ側エラー)
ターミナル2: `07_fd_limit.rb` でfd枯渇 (OS側エラー)

両方を体験すると、**「接続できない」エラーの原因切り分け**ができるようになる。

### セット3: TIME_WAIT問題を起こしてみる

```bash
# ループでconnを開いては閉じるスクリプトを書いて
# その間に状態を観察
ss -tan state time-wait | wc -l
```

→ 短時間に大量の接続を作るとTIME_WAITが溜まる。これがプロダクションで「ポート枯渇」を起こす原因。

---

## まとめ: どのコマンドを覚えるべきか

最低限これだけ覚えておけば現場で困らない:

```bash
# 1. プロセスの接続を見る (これが最頻出)
lsof -p <PID> -a -i TCP        # macOS / Linux 両方
ss -tnp | grep <PID>           # Linux なら高速

# 2. fd 上限と現在値
ulimit -n
ls /proc/<PID>/fd | wc -l      # Linux
lsof -p <PID> | wc -l          # macOS

# 3. DB側のプロセス
SHOW PROCESSLIST;              # MySQL
SELECT * FROM pg_stat_activity; # PostgreSQL

# 4. パケット捕捉 (デバッグ時の最終兵器)
sudo tcpdump -i lo -nn 'port 3306' -A
```
