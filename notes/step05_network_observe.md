# Step 5: pool.stat と OS のソケット情報を突き合わせる

> `scripts/05_network_observe.rb` のハンズオン観察ノート

---

## 1. このスクリプトで何を確かめるのか

Rails の `pool.stat` で見える **「コネクション」**、OS の `lsof` で見える **「TCPソケット」**、
MySQL の `SHOW PROCESSLIST` で見える **「1行のプロセス」** が、
**すべて同じ実体を 3 つの角度から見ているだけ** であることを、実機で確認する。

具体的には、スクリプトの 5 段階で以下を観察する:

| 段階 | やること | 観察したいこと |
|------|---------|---------------|
| ① | 起動直後 | OS側にTCP接続が無いこと(connections: 0) |
| ② | 1回クエリ実行 | OS側にESTABLISHED接続が1本現れる |
| ③ | 3スレッド並行で長いクエリ | OS側のTCP接続数が busy 数と一致する |
| ④ | 全スレッド終了後 | busy=0 でも OS側のESTABLISHED接続は残る(使い回し) |
| ⑤ | `pool.disconnect!` | OS側の接続が消える、TIME_WAITで残る場合も |

---

## 2. なぜ学ぶ価値があるか

これまで Step 1〜4 では Rails 内部だけを観察してきた。
しかし本番で「DB に接続できない」エラーが起きたとき、原因は **3 つのレイヤー** に分散している:

| レイヤー | 原因の例 | 見るべきもの |
|---------|---------|------------|
| アプリ層 (Rails) | プール枯渇、conn リーク | `pool.stat`, ログ |
| OS層 | fd 上限、ポート枯渇、TIME_WAIT 大量 | `lsof`, `ss`, `ulimit` |
| DB層 | `max_connections` 超過、ロック | `SHOW PROCESSLIST` |

**3 つの視点を同時に見られる人だけが、原因の切り分けができる**。
Step 5 はその訓練の入り口。

また、TCP の **TIME_WAIT** 状態を初めて目で見る回でもある。
「切断したのに接続情報が残る」現象を体感しておくと、本番で TIME_WAIT が大量発生して
ポート枯渇するタイプの障害がイメージできるようになる。

---

## 3. 事前知識(Step 1〜4 からの引き継ぎ)

### コネクション = TCPソケット = fd の対応関係

```
Rails視点:    "コネクション" "conn"
                    ↓
OS視点:       TCPソケット (fd 1個)
                    ↓
ネットワーク: 3306番ポートへのTCP接続 (ESTABLISHED状態)
                    ↓
DB視点:       PROCESSLIST に1行
```

すべて **同じ実体を別の角度から見ている**。

### pool.stat のキー

| キー | 意味 |
|------|------|
| size | 最大本数の設定値 |
| connections | 実際に繋いだ本数 |
| busy | 使用中の本数 |
| idle | 空いている本数 |
| waiting | 空きを待っている人数 |

関係式: `busy + idle = connections`、`connections ≦ size`

### Rails側 busy/idle と DB側 Query/Sleep の対応(Step 3)

| Rails 側 | DB 側 | 意味 |
|---------|------|------|
| busy | Query | クエリ実行中 |
| idle | Sleep | 接続は生きているが何もしていない |

`idle = 切断されていない`。TCP 接続は維持されたまま。

### 遅延生成(Step 1)

`establish_connection` だけでは接続は貼られない。
**初めて SQL を投げた瞬間** に 1 本貼られる。

### Step 5 で初登場する用語

- **TCPソケット**: TCP接続の端点。OS が管理する通信路の口。
- **fd (file descriptor)**: OS が「開いているもの」を管理する整数番号。TCPソケットも fd で管理される。
- **ESTABLISHED**: TCP の状態。「今まさに繋がっている」状態。
- **TIME_WAIT**: TCP の状態。切断直後、約60秒残る。遅れて届くパケットを受けるための仕様。
- **PID**: プロセスID。`lsof -p <PID>` で覗く。
- **lsof**: list of open files。fd を覗く万能コマンド。

---

## 4. 実行前の予想

> 実行する前に、以下の質問に自分の言葉で答えてみる。
> 後で実際の出力と突き合わせて、ズレを観察ノートに残す。

### 段階 ①(起動直後、まだ何もしていない状態)

- Q1-1. `pool.stat` の `connections` はいくつ?
    - **予想:** 0。establish_connection だけでは接続は貼られない(遅延生成)。
      実際に SQL を投げた瞬間に初めて 1 本貼られる(Step 1 で観察済み)。

- Q1-2. `lsof -p <PID> | grep TCP` の出力にMySQLへの接続(ポート3306)は現れる?
    - **予想:** 現れない。Rails が conn を持っていない以上、OS 側にも TCP ソケットは存在しないはず。

- Q1-3. `SHOW PROCESSLIST` に自分の Rails プロセスからの接続は見える?
    - **予想:** 見えない。MySQL 側からも Rails 由来の接続は映らないはず。
      ただし event_scheduler や PROCESSLIST 自身は映る(これは無視)。

### 段階 ②(1回 SELECT 1 を実行した後)

- Q2-1. `pool.stat` の `connections` と `busy` と `idle` はいくつ?
    - **予想:** connections: 1, busy: 0, idle: 1
      SELECT 1 は瞬時に終わるので、観察時には checkin 済み(idle)。

- Q2-2. OS側に何本のTCP接続が見える? その状態は?
    - **予想:** 1 本、ESTABLISHED
      (最初は「TIME_WAIT?」と予想したが、idle = ESTABLISHED であることを学んだ。
      Rails 視点で busy↔idle が切り替わっても、OS 視点では ESTABLISHED のまま。
      これが「使い回し」の正体。TIME_WAIT は切断後にしか出ない。)

- Q2-3. DB側 SHOW PROCESSLIST には何が見える? Command カラムは何?
    - **予想:** root@localhost からの接続が 1 行、Command=Sleep
      Rails 側 idle ↔ DB 側 Sleep の対応(Step 3 の知見)。

## 段階② 予想

| 視点 | 予想 |
|------|------|
| Rails | `connections:1, busy:1, idle:0`(段階①と同じ) |
| OS | ESTABLISHED 1 本、fd 6番(段階①と同じ) |
| DB | Sleep 1 行、ただし Time が小さい値にリセット(SELECT 1 直後だから) |

### 段階 ③(3スレッド並行)

- Q3-1. pool.stat はどうなる?
    - **予想:** size:5, connections:3, busy:3, idle:0
      既存の idle 1本が再利用 + 新規2本貼る = busy 3本

- Q3-2. OS側のTCPソケット数は何本?
    - **予想:** 3本(ESTABLISHED)。connections と同じ数。

- Q3-3. DB側 PROCESSLIST の Command カラムは?
    - **予想:** Query が 3 行(SELECT SLEEP(...) のはず)
      ※ SHOW PROCESSLIST を叩いた自分自身の Query 行も含めると見かけ4行

- Q3-4. Rails の busy と OS の TCPソケット数と DB の Query 行数は一致する?
    - **予想:** 一致する。3 = 3 = 3
      これが Step 5 で目で見たい中核。

### 段階 ④(全スレッド終了後、まだ disconnect していない)

- Q4-1. pool.stat の busy と idle はどうなる?
    - **予想:** busy:0, idle:3, connections:3
      クエリ完了で全 conn が checkin される。connections は減らない。

- Q4-2. OS側のTCP接続は減る? 残る? 状態は?
    - **予想:** 3 本そのまま、状態は ESTABLISHED
      idle = ESTABLISHED のままが鉄則(段階② で学んだ)

- Q4-3. DB側の Command カラムはどう変わる?
    - **予想:** Sleep が 3 行
      Rails 側 idle ↔ DB 側 Sleep の対応(Step 3)を3本ぶん。

- Q4-4. 段階③と段階④で、OS から見た接続数は変わる?変わらない?
    - **予想:** 変わらない
      ★ Step 5 のクライマックス。
      Rails 視点では busy↔idle が動くが、OS 視点は ESTABLISHED で固定。
      これが ConnectionPool の本質(=次回のクエリで handshake/認証を省略するため)。

### 段階 ⑤(pool.disconnect! 直後)

- Q5-1. pool.stat の connections はいくつ?
    - **予想:** 0。プールが空になる。

- Q5-2. OS側のTCP接続は すぐに 消える?
    - **予想:** すぐには消えない。

- Q5-3. もし残るとしたら、状態は何?
    - **予想:** TIME_WAIT。切断後、約60秒残る(遅れて届くパケットを受けるため)。

- Q5-4. DB側 SHOW PROCESSLIST から該当の接続は消える?
    - **予想:** すぐ消える
      (最初は「TIME_WAIT してるから消えない?」と予想したが、間違いだった。
      TIME_WAIT は「切った側 = Rails」の OS 上に残る現象。
      「切られた側 = MySQL」は相手が切ったことを即認識して削除する。
      つまり段階⑤ では3視点が初めてズレる:
      Rails: 0, OS: TIME_WAIT 残存, DB: すぐ削除)

---

## 5. 実際の出力

### 段階 ①(起動直後)

#### 実際の出力

T1 (Rails 起動ログ):
-- drop_table(:users, {if_exists: true})
-- create_table(:users)
PID: 23124

T2 (lsof):
ruby 23124 mami.hirono 6u IPv4 ... TCP localhost:56447->localhost:mysql (ESTABLISHED)

T3 (SHOW PROCESSLIST):
63  root  10.4.0.1:51724  playground  Sleep  49  NULL

#### 予想とのズレ

予想: 3視点とも「無い」ことを期待
実際: 3視点とも 1 本/1 行 が存在

#### 学び

★ スクリプトは PID 表示前に drop_table, create_table を実行していた。
この時点で「初めての SQL」が走り、遅延生成で conn が 1 本貼られていた。
★ Step 1 で学んだ「create_table も SQL 発行 → conn 貼られる」が再現。
★ ただし「3視点が一致する」という Step 5 の核心は段階①で既に確認できた。
1 (Rails) = 1 (OS ESTABLISHED) = 1 (DB Sleep行)

### 段階 ②(1回クエリ実行後)

#### 実際の出力

T1 (Rails):
{size: 5, connections: 1, busy: 1, idle: 0}

T2 (lsof):
ruby 23124 mami.hirono 6u IPv4 ... TCP localhost:56447->localhost:mysql (ESTABLISHED)

T3 (PROCESSLIST):
63 root 10.4.0.1:51724 playground Sleep 2 NULL

#### 結果: 全予想通り

- Rails の数字は変わらず (busy:1 のまま) → メインスレッドが既存 conn を再利用
- OS の fd 番号 6u、ローカルポート 56447 が段階① と同じ → 同じ TCP ソケットを使い回し
- DB の Id 63 が段階① と同じ、Time だけ 49 → 2 にリセット → 同じ MySQL プロセス

#### 学び

★ 「3 視点で同じものを別の証拠で確認」できた:
- Rails: connections 数
- OS: fd 番号 + ポート番号
- DB: MySQL の Id
  ★ 唯一動くのは DB 側の Time(最後の SQL からの経過秒数)
  → これが「使い回し中でも、何かは起きてる」唯一の痕跡
  ★ ConnectionPool は、OS レベルで物理的に同じソケットを保持し続けている

### 段階 ③(3スレッド並行)

#### 実際の出力
- Rails: connections:4, busy:4, dead:0, idle:0
- OS: ESTABLISHED が 4 本(fd 6u, 7u, 10u, 11u)
- DB: Query 3 行(Id 66/67/68 が SELECT SLEEP)+ Sleep 1 行(Id 63)

#### 予想とのズレ
- 予想は 3 だったが、実際は 4
- 理由: 段階② から継続のメインスレッドの conn(fd 6u, Id 63)が
  busy:1 として残っており、新規 3 本が追加された
- これは段階② の「メインスレッドが持ち続ける」現象が継続しているため

#### 学び
★ Rails connections 数 = OS ESTABLISHED 数 = DB の Rails 由来行数 で 4 = 4 = 4 一致
★ ただし、Rails busy ≠ DB Query 数(busy: 4 のうち、Query は 3 行)
★ メインスレッドは持ってるだけ(busy だが Sleep)、新規スレッドだけが実際に SQL 実行中
★ fd 6u と Id 63 が段階①②③ で一貫して同じ → 同じ TCP ソケットを物理的に使い続けている

### 段階 ④(全スレッド終了後、disconnect 前)

#### 実際の出力(再実行版、PID=23516)

T1 (Rails):
{size: 5, connections: 4, busy: 1, dead: 3, idle: 0}

T2 (lsof):
fd 6u, 7u, 9u, 12u すべて ESTABLISHED(4 本)

T3 (PROCESSLIST):
74  root  ...  Sleep  16  ← メインスレッド
76  root  ...  Sleep  13  ← 新規スレッド1(終了済み)
77  root  ...  Sleep  13  ← 新規スレッド2(終了済み)
78  root  ...  Sleep  13  ← 新規スレッド3(終了済み)

#### 3 視点の数字: 4 = 4 = 4 で完全一致

#### 予想とのズレと学び

★ 「dead」状態でも OS は ESTABLISHED、DB は Sleep のまま
→ Rails の論理的な状態と、OS の物理的な状態は独立している

★ 数字は 4 で一致するが、Rails 内部での内訳は busy:1 / dead:3 と複雑
→ Rails の状態管理は「論理的な台帳」であって、TCP の実体ではない

★ これがプロダクションの罠の入り口
「Rails は idle と言ってるのに、OS では大量の ESTABLISHED が残ってる」
というタイプの障害が想像できるようになった

#### Rails ↔ OS ↔ DB の対応マッピング

| Rails 状態 | OS fd | DB Id | DB Time | DB Command |
|---------|------|------|--------|----------|
| busy:1 | 6u | 74 | 16 | Sleep |
| dead | 7u | 76 | 13 | Sleep |
| dead | 9u | 77 | 13 | Sleep |
| dead | 12u | 78 | 13 | Sleep |

### 段階 ⑤(pool.disconnect! 直後)

#### 実際の出力

T1 (Rails):
{size: 5, connections: 0, busy: 0, dead: 0, idle: 0}

T2 (lsof -p 23516 | grep TCP):
(空っぽ。プロセスから fd が外れた)

T3 (PROCESSLIST):
Rails 由来の Sleep 行は全て即座に消えた。

#### 追加検証: lsof -i TCP / netstat -an -p tcp | grep 3306
- limactl が localhost:mysql で LISTEN(待ち受け)しているだけ
- TIME_WAIT は見えなかった

#### TIME_WAIT が見えなかった理由(発見した学び)

Finch は VM の中で動いている:
Mac (Ruby) → localhost:3306 → Lima VM → Finch コンテナ → MySQL

→ TIME_WAIT は Lima VM や Finch コンテナの中に残っているはずで、
Mac の lsof / netstat からは見えない。

#### 重要な学び
★ 観察ツールには「見える範囲」がある
★ ローカル直で MySQL を動かしているなら見えたはず
★ コンテナ・VM 越しの通信は、ホスト OS から見えないレイヤーがある
★ これは本番のトラブルシューティングでも重要(コンテナ内の状態を見るには中に入る必要がある)

#### TIME_WAIT を実機で見たいなら(将来トライ)
- finch vm shell で VM に入って netstat
- finch exec ar-mysql で コンテナに入って netstat
- Step 6 の tcpdump でパケットレベルで観察
- Mac 直で MySQL を動かす(brew install mysql)

---

## 6. 気づいたこと・疑問(予想とのズレ含む)

#### 補足の気づき(Step 4a の知識との接続)

実際の段階① の Rails stat は busy: 1, idle: 0 だった。
予想していた「idle: 1」ではなく busy のまま。

これは「メインスレッドは一度 checkout した接続を持ち続ける」仕様のため。
- create_table の処理が終わっても、スレッドが生きている限り conn は返却されない
- これが ActiveRecord の同一スレッド保証(Step 4a)の裏返し
- Web リクエストではミドルウェアが自動で返却するが、素のスクリプトでは発動しない

→ 段階② で SELECT 1 を投げても、メインスレッドが既に持っている busy:1 の conn を
そのまま使い回すはずなので、数字は変わらない見込み。

## 6. 気づいたこと・疑問

### 予想と一致したこと

- 段階② で 1 回クエリ → connections は 1 のまま、再利用された(fd 6u が継続)
- 段階③ で 3 視点の数字が連動して動いた(完全一致ではないが連動を確認)
- 段階⑤ で Rails の connections は 0、DB から Rails 由来の行は即削除

### 予想とズレたこと(=今日の最大の学び)

#### ① 段階① で既に 1 本貼られていた
- 予想: 起動直後は 0 本
- 実際: connections:1, busy:1
- 理由: スクリプトが PID 表示前に drop_table/create_table を実行していた
- 学び: Step 1 の「create_table も SQL → 遅延生成発動」の再現

#### ② busy のまま自動返却されない
- 予想: クエリ終了後は idle に戻るはず
- 実際: メインスレッドが busy:1 のまま持ち続けた
- 理由: ActiveRecord は同一スレッドでの再利用を見込んで自動返却しない
- 学び: 自動返却は Web リクエスト終了時 or スレッド終了時に起きる仕様

#### ③ 段階③ で数字が 3 ではなく 4 になった
- 予想: connections:3, busy:3
- 実際: connections:4, busy:4
- 理由: メインスレッドの 1 本 + 新規 3 本 = 4 本
- 学び: 「同一スレッド保証」が働く限り、メインスレッドの conn は保持される

#### ④ Rails busy ≠ DB Query
- 段階③ で Rails busy:4 だったが、DB の Query 行数は 3 だけ
- 残り 1 つは Sleep(メインスレッドの conn)
- 学び: busy は「貸し出し中」、Query は「SQL 実行中」、別の概念

#### ⑤ dead 状態が初登場
- 段階④ で busy:1, dead:3 に
- スレッド終了で紐付いた conn が dead 扱いに
- ただし OS 視点では ESTABLISHED のまま、DB 視点でも Sleep のまま
- 学び: 「dead」は Rails 内部のラベル、TCP の実体とは別

#### ⑥ TIME_WAIT が Mac の lsof で見えない
- Finch は VM 経由で動いている(Lima VM → コンテナ → MySQL)
- TIME_WAIT は VM の中で起きていて、Mac からは見えない
- 学び: 観察ツールには「見える範囲」がある、コンテナ越しの通信は別レイヤー

### 新しく出てきた疑問・モヤモヤ

- TIME_WAIT を実機で見るには、VM やコンテナの中に入る必要がある
- 本番(クラウド)で TIME_WAIT を見るのはどう?
  → Step 6 の tcpdump や、本番では監視ツール(NewRelic, Datadog)経由で見る話に繋がりそう
- メインスレッドの conn が持ったままの仕様は、Web では問題にならないけど、
  バッチ処理スクリプトでは何か対処が必要?

### 自分の体感メモ

- 「3 視点で見る」と言っていたが、実際は「内訳が違うけど数字は一致する」が正確だった
- fd 番号と DB の Id を突き合わせるとマッピングが取れて気持ちいい
- 観察コマンドの選び方(lsof -p vs lsof -i)で見える範囲が違うのは要注意

---

## 7. 学習チェックポイント

## 7. 学習チェックポイント

以下を「自分の言葉」で説明できるかチェック。
できれば短い文章で書いてみる(空白のまま放置せず、後日でもいいから埋める)。

### 必須(Step 5 のコア)

- [ ] Q1. Rails の `pool.stat` の `connections` 数 = OS の ESTABLISHED 数 = DB の PROCESSLIST の Rails 由来行数 になることを実機で確認した
      - 自分の言葉:3 つの数字が同じになるのは、Rails のコネクションも、OS の TCP ソケットも、 DB のセッションも、すべて同じ 1 本の通信路を別の視点から呼んでいるだけだから。 別々のものではなく、同じ実体を 3 つの角度から数えていると言える。

- 「3 つの数字が同じ」ことが意味するのは:

Rails の "コネクション 1 本"
= OS の "TCP ソケット 1 個"
= DB の "PROCESSLIST 1 行"

これらは別々のものではなく、同じ 1 つの通信路を
3 つの異なるレイヤーから観察した呼び方の違いに過ぎない。

だから数が一致するのは当然で、
逆に「数が一致しない」ことがあれば、それはどこかでズレが起きている異常な状態。

- [ ] Q2. 「Rails が conn を貼る」とは、OS レベルで何が起きていることなのか説明できる
    - 自分の言葉:「Rails が conn を貼る」とは、OS が新しい TCP ソケットを 1 個作り、
      fd(ファイルディスクリプタ)を 1 個割り当て、MySQL との通信路を
      ESTABLISHED 状態にすることを指す。
      lsof で見ると "fd番号 + ESTABLISHED" の 1 行として現れる。

- [ ] Q3. 段階④ で `busy=0` になっても OS 側の ESTABLISHED が残る理由(=コネクションプールの「使い回し」)を説明できる
    - 自分の言葉:もし毎回切っていたら、3way handshake と MySQL 認証を毎回行う必要があり、
      それぞれ数 ms〜数十 ms かかるので合計で重い処理になってしまう。
      電話を一度切ってかけ直すより、繋いだまま使い回す方が圧倒的に効率が良い。
      だからアイドルになっても切らずに ESTABLISHED のまま維持しておく。
      これがコネクションプールの「使い回し」の正体。

- [ ] Q4. メインスレッドが checkout したまま持ち続ける理由を説明できる
    - 自分の言葉:ActiveRecord は同一スレッド保証(Thread.current で conn を管理)の前提に立っている。
      同じスレッドからまた SQL が来る可能性が高い(Web のリクエスト処理中など)ので、
      すぐに返却するより持ったまま使い回す方が効率的。
      自動返却は ① Web リクエスト終了時のミドルウェア処理、
      ② スレッド終了時、③ 明示的な with_connection ブロック終了、で発生する。
      今回のスクリプトのメインスレッドは ①②③ どれも発動しないため、
      持ち続けて busy のまま見えた。

### 発展(今日の学び)

- [ ] Q5. Rails の busy と DB の Query 行数が必ずしも一致しない理由を説明できる
    - 自分の言葉:

- [ ] Q6. 「dead」状態が、OS から見ると ESTABLISHED であり得ることを説明できる
    - 自分の言葉:

- [ ] Q7. fd 番号(lsof の `6u`)と DB の Id を突き合わせれば、どの conn がどのスレッドのものか特定できることを実演できる
    - 自分の言葉:

### 実務応用

- [ ] Q8. 本番で「DB に接続できない」エラーが出たとき、3 レイヤーのどこを見るべきかが頭に浮かぶ
    - 自分の言葉:

- [ ] Q9. 観察ツールには「見える範囲」がある(lsof -p vs lsof -i、ホスト OS vs コンテナ内)ことを認識している
    - 自分の言葉:

### 持ち越し(Step 6 へ)

- [ ] Q10. TIME_WAIT 状態を実機で観察できる(Step 6 の tcpdump で見る予定)
    - → Step 6 で達成見込み

---

## 8. 次のステップへの伏線

### Step 5 で持ち越したこと

#### TIME_WAIT を実機で見る(Step 6 で再挑戦)

- 段階⑤ で `pool.disconnect!` 直後に Mac の lsof / netstat で TIME_WAIT を狙ったが、
  Finch が VM 経由で動いている都合で見えなかった
- Step 6 の tcpdump で「切断時のパケットの流れ(FIN → FIN-ACK)」をパケットレベルで観察すれば、
  TIME_WAIT の世界が別の角度から見えるはず
- もしくは finch vm shell で VM の中に入って netstat を叩く手もある

#### dead 状態の挙動をもう少し追う

- 段階④ で busy:1, dead:3 と出たが、その後どこで dead な conn は片付くのか?
- ずっと dead のままなら、connections が膨らんでいきそうだが、実際は disconnect で消えた
- Rails 内部での dead conn の刈り取り(reaper / reaping_frequency 設定)を後で確認したい

### Step 6 で何を見たいか

#### tcpdump でパケットレベルの観察

- 今日は「TCP ソケットがある/ない」レベルの粒度だった
- Step 6 では「そのソケットの中で実際にどんなバイト列が流れてるか」を見る
- 観察したいもの:
    - SYN → SYN-ACK → ACK の 3way handshake
    - MySQL のバージョン文字列が平文で流れる(Greeting)
    - ユーザー名が平文で送信される
    - SQL クエリ本文が平文で見える
    - FIN による切断
- → 「TLS が必要な理由」を体感する

#### Step 5 の段階② を tcpdump で見直す

- 段階② で fd 6u が変わらず使い回された = 同じソケット上で複数 SQL が流れたはず
- tcpdump で「最初の handshake は最初だけ、その後はクエリだけが流れる」が見えれば、
  Step 5 の理解が完璧に裏付けられる

### Step 7 で何を見たいか

#### fd 上限(ulimit -n)に意図的に当てる

- 今日は fd 6u, 7u, 9u, 12u と 4 個しか使わなかった
- Step 7 では大量に conn を貼って Too many open files を起こす
- 学びたいこと:
    - ulimit -n で確認できる現在の上限値
    - プールサイズと fd 上限の関係
    - 本番でよくある「謎の接続エラー」の正体の一つ

### 周辺技術(更に先のトピック)

- PgBouncer / RDS Proxy: 「アプリと DB の間にもう一段プールを挟む」理由が、
  Step 5 で押さえた「使い回しコスト」と「max_connections 圧迫」の両方から見えた
- TLS/SSL: Step 6 で見える「平文通信」の暗号化
- strace / dtruss: システムコールレベルで connect()/read()/write() を追う
  → fd と conn の関係をさらに深く見られる

### 自分の体感メモ(自由記述)

- (今日のハンズオンで「これは将来も使えそう」と思った道具・知識を書く)
- 例: lsof -p と lsof -i の使い分け、PROCESSLIST の Time カラムの読み方、など