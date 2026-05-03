# Step 3: DB側のprocesslistと突き合わせ

実行日: 2026-05-03
環境: macOS / Finch (containerd) / MySQL 8.4.9 (コンテナ)

## 実行前の予想

### 質問1: フェーズ ① 起動直後の Rails 側 pool.stat

**予想**:
- `connections: 1, busy: 1, idle: 0, waiting: 0`

**理由**:
- Step 1 で「`create_table` の時点で 1 本貼られる」「メインスレッドは持ち続ける」
  という気づきがあった
- スクリプトの `show_rails_side` / `show_db_side` 関数も SQL を投げるので、
  メインスレッドが 1 本 checkout した状態が続く
- まだ並行スレッドは作られていないので、増えない

---

### 質問2: フェーズ ② 並行クエリ実行中の Rails 側 pool.stat

**予想**:
- `connections: 4, busy: 4, idle: 0, waiting: 0`

**理由**:
- 並行 3 スレッドだけだと 3 本に見えるが、**メインスレッドの存在を忘れない**
- メインスレッドは `show_rails_side` / `show_db_side` を実行している(= conn 借りている)
- 3 スレッドはそれぞれ `with_connection` で 1 本ずつ checkout して `sleep 3` 中
- 合計 = 1 (メイン) + 3 (並行) = **4 本**
- pool size は 5 なので、4 本までは余裕で貼れる

**最初に間違えた予想**:
- 最初は connections=3 と予想したが、メインスレッドの分を忘れていた

---

### 質問3: フェーズ ② のとき DB 側 processlist は何行?

**予想**:
- 4 行
- Rails 側 `connections=4` と一致するはず

**command 列の内訳予想**:
| 誰 | command | 理由 |
|----|---------|------|
| メインスレッド | `Query` | 今まさに `processlist` を SELECT している最中 |
| Thread 0 | `Sleep` | INSERT は終わって `sleep 3` 中 |
| Thread 1 | `Sleep` | 同上 |
| Thread 2 | `Sleep` | 同上 |

つまり: **Query 1 行 + Sleep 3 行 = 計 4 行**

**面白いポイント**:
- スクリプト自身が processlist を覗いている瞬間が、そのまま
  processlist の中に Query として映る(鏡を覗いている自分が映る感覚)

---

### 質問4: フェーズ ③ 全スレッド終了後の変化

**Rails 側の予想**:
- 3 つのスレッドが `with_connection` のブロックを抜けて自動 checkin される
- `connections: 4` のまま(= 接続自体は切れていない)
- `busy: 1`(メインスレッドのみ)
- `idle: 3`(返却された 3 本)

**理由**:
- `with_connection` を抜けると自動 checkin される(Step 1 で確認済み)
- checkin されたコネクションは「切断」ではなく「待機状態」になる
- → **busy が減って idle が増える**

**DB 側の予想**:
- 行数は 4 のまま変わらない
- ただし command が変化:
    - メインスレッド: `Query`(まだ動作中)
    - Thread 0〜2 の使っていた conn: `Sleep`(idle で残る)
- = Query 1 行 + Sleep 3 行(②と同じ見え方)

**理由**:
- DB 側は「使い回すためにわざと切らずに置いてある」(スクリプトのコメントより)
- Rails 側で idle になっても、TCP 接続は生きている → DB から見ると Sleep のまま

---

## 観察ポイント(予想を立てる中で出てきた疑問)

- [ ] フェーズ ② で connections が本当に 4 になるか?
  (3 と勘違いしないか)
- [ ] DB 側の Query / Sleep の内訳が予想通りか
- [ ] フェーズ ③ で busy=1, idle=3 になるか
- [ ] フェーズ ③ で DB 側の行数が変わらないか
  (= idle 接続が DB から見えているか)
- [ ] スクリプト自身の SELECT が processlist に映るのを目視できるか

---

## 実際の出力

(ここに実行結果を貼る)

## 実際の出力
```
=== ① 起動直後 ===
--- Rails側のpool.stat ---
size=5 connections=1 busy=1 idle=0 waiting=0
--- DB側のprocesslist (db=playground) ---
id=21 user=root command=Query time=0s state=executing
conn数: 1
=== ② 3スレッドで並行クエリ実行中 ===
--- Rails側のpool.stat ---
size=5 connections=4 busy=4 idle=0 waiting=0
--- DB側のprocesslist (db=playground) ---
id=21 user=root command=Query time=0s state=executing
id=22 user=root command=Sleep time=1s state=
id=23 user=root command=Sleep time=1s state=
id=24 user=root command=Sleep time=1s state=
conn数: 4
=== ③ 全スレッド終了後 ===
--- Rails側のpool.stat ---
size=5 connections=4 busy=1 idle=3 waiting=0
--- DB側のprocesslist (db=playground) ---
id=21 user=root command=Query time=0s state=executing
id=22 user=root command=Sleep time=3s state=
id=23 user=root command=Sleep time=3s state=
id=24 user=root command=Sleep time=3s state=
conn数: 4
```

別ターミナルから `SHOW PROCESSLIST` を実行した結果:
```
| Id | User            | Host           | db         | Command | Time | State                  | Info             |
|  5 | event_scheduler | localhost      | NULL       | Daemon  | 1222 | Waiting on empty queue | NULL             |
| 21 | root            | 10.4.0.1:57060 | playground | Sleep   |    1 |                        | NULL             |
| 22 | root            | 10.4.0.1:57070 | playground | Sleep   |    2 |                        | NULL             |
| 23 | root            | 10.4.0.1:57080 | playground | Sleep   |    2 |                        | NULL             |
| 24 | root            | 10.4.0.1:57084 | playground | Sleep   |    2 |                        | NULL             |
| 25 | root            | localhost      | NULL       | Query   |    0 | init                   | SHOW PROCESSLIST |
```

---

## 気づいたこと・疑問

### 予想とのズレ

予想は全部当たった。特に以下を当てられたのは大きい:

- フェーズ ② の connections=4(メインスレッドの存在を忘れずに数えられた)
- フェーズ ③ の Rails側 busy=1, idle=3(`with_connection` の自動 checkin の挙動)
- DB 側の Query/Sleep の内訳

最初は connections=3 と思ったが、メインスレッドも `show_rails_side` / `show_db_side` を
実行するために 1 本 checkout していることに気づいて 4 に修正した。


### Rails 側 busy/idle と DB 側 Query/Sleep の対応関係

| Rails 側 | DB 側 | 意味 |
|---------|------|------|
| busy | Query | クエリ実行中 |
| idle | Sleep | 接続は生きているが何もしていない |

- `idle = 切断されていない`
- TCP 接続は維持されたまま、MySQL からは「Sleep」状態に見える
- Rails の pool.stat で idle と書かれていても、DB 側はリソースを消費している

### スクリプト自身の SELECT が processlist に映る

「鏡を覗く」のような構造:

- フェーズ ① で `command=Query` になっているのは、`show_db_side` で
  `SELECT * FROM information_schema.processlist` を実行している、その SQL 自体が
  processlist の中に映っているから
- スクリプト自身がまさに観察対象になっている

別ターミナルから `SHOW PROCESSLIST` を叩くと、id=21 は `Sleep` に戻っていて、
代わりに別ターミナルの `SHOW PROCESSLIST` 自身が新しい id=25 として
`command=Query` で映っていた。これは `processlist` が **スナップショット** だから。

### with_connection についての誤解と訂正

**最初の誤解**:
「`with_connection` はコネクションを使い回す仕組み」と思っていた。
だから連続する 3 スレッドでも 1 本で済むのでは、と予想していた。

**正しい理解**:
- `with_connection` は「借りたら明示的に返す」仕組み
- 1 本のコネクションを複数スレッドで共有することはできない(電話の通話と同じ)
- 並行スレッドが N 個あれば、N 本の conn が必要
- `with_connection` が「最小化」しているのは「借りっぱなしになる時間」

**「使い回す」と「再利用する」は別の話**:

| 概念 | 主体 | タイミング |
|------|------|-----------|
| 使い回す(連続使用) | 同じスレッド | 同じブロック内で連続クエリを 1 本で処理 |
| 再利用する | ConnectionPool | 返却された idle 接続を別のスレッドが借りる |


### コネクションプールの「再利用」の優先順位

新しいスレッドが checkout を要求したときの動き:

1. idle のコネクションがあれば、それを再利用(busy に変える)
2. idle がなく、size に余裕があれば、新しく 1 本作る
3. size も尽きたら、waiting に並ぶ

「新しく作る」のは最終手段。これは TCP ハンドシェイク + MySQL 認証の
コストを避けるため(数十ms〜100ms かかる)。

### 一度貼った接続は、disconnect! しない限り残る

フェーズ ③ で connections=4 のまま、busy=1, idle=3 になっている。
スレッドが終わっても、貼ったコネクションは「切らずに idle として待機」する。

これは:
- 次に必要になったときに即座に再利用できる
- TCP ハンドシェイクと認証のコストを払わなくて済む

ただし副作用として:
- 「アプリは静かなのに DB 側の `Threads_connected` が高止まり」が起きる
- Rails のプロセス数 × pool size が DB の `max_connections` を超えると問題になる


### MySQL 内部の接続(playground 以外)

別ターミナルで `SHOW PROCESSLIST` を絞り込みなしで叩くと、
`event_scheduler` という MySQL 内部の Daemon プロセスが 1 つ存在していた。

スクリプトの SQL は `WHERE db = 'playground'` で絞っていたので、
これが除外されていた。

本番の MySQL を覗くと、レプリケーション接続、内部の管理用接続など、
アプリと無関係なものがいろいろ並んでいる。

### 実務に繋がる気づき

pool size を決めるときの基準:

「同時に DB アクセスする可能性がある最大スレッド数 + 余裕」

- Puma のスレッド数(リクエスト処理)
- Sidekiq のワーカースレッド数(バックグラウンドジョブ)
- 自前で Thread.new するバッチ処理

これらの合計 + α が、ピーク時の `connections` 数になる。
足りないと `ConnectionTimeoutError`(Step 2 で再現した状態)。

## 学習チェックポイント

- [x] Rails の busy = MySQL の Command=Query を確認できた
- [x] Rails の idle = MySQL の Command=Sleep を確認できた
- [x] スクリプト自身の SELECT が processlist に映るのを目視できた
- [x] フェーズ ③ で TCP 接続が切れずに残っていることを確認できた
- [x] `with_connection` は「使い回し」ではなく「明示的な返却」のための仕組みだと理解した
- [x] ConnectionPool は idle を優先的に再利用することを理解した
- [x] pool size を決める基準(同時並行スレッド数)が言える