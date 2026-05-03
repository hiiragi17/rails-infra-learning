# Step 1: pool.stat でプールを覗く

実行日: 2026-05-03
環境: macOS

## 実行前の予想
質問：
スクリプトを起動した直後(まだ何のクエリも投げていない時点)、connections の値はいくつだと思うか。

答え：
connections: 0 になると思う。

理由：

- README に「電話は使うときに初めて繋ぐ(=遅延生成)」とあった
- 起動しただけでは誰もクエリを投げていないので、まだ電話を1本も繋ぐ必要がない
- size=5 はあくまで「最大5本まで用意できる」という枠であって、
  実際に繋ぐかどうかは別

予想する出力:
{size: 5, connections: 0, busy: 0, idle: 0, waiting: 0}

## 実際の出力
bundle exec ruby 01_pool_stat.rb
-- create_table(:users)
-> 0.0057s
--- 起動直後 (まだクエリを叩いていない) ---
{size: 5, connections: 1, busy: 1, dead: 0, idle: 0, waiting: 0, checkout_timeout: 2.0}

--- 1回クエリを叩いた直後 ---
{size: 5, connections: 1, busy: 1, dead: 0, idle: 0, waiting: 0, checkout_timeout: 2.0}

--- 手動 checkout した状態 ---
{size: 5, connections: 2, busy: 2, dead: 0, idle: 0, waiting: 0, checkout_timeout: 2.0}

--- checkin で返却した後 ---
{size: 5, connections: 2, busy: 1, dead: 0, idle: 1, waiting: 0, checkout_timeout: 2.0}

■ 観察ポイント
- 起動直後は connections=0 (遅延生成)
- クエリ後 connections は 1 になり、idleに戻る
- checkout → busy が増え、checkin → idle に戻る
- size は設定値(5)、connections は実際に貼られた本数

## 気づいたこと・疑問

### 予想とのズレ
- 予想: 起動直後は connections=0
- 実際: 起動直後でも connections=1, busy=1
- 理由: create_table が動いた時点で既に1本 checkout されていた
  「起動直後」というラベルが少し誤解を招く

### 手動 checkout の動き
- pool.checkout で2本目が借りられる → connections=2, busy=2
- pool.checkin で返却 → busy が1減って idle が1増える
- 一度貼った接続は、disconnect しない限り idle として残る

### コネクションが貼られるタイミング
- establish_connection だけでは貼られない(=接続情報の登録のみ)
- 初めて SQL を投げた瞬間に1本貼られる(=遅延生成、lazy connection)
- SQL がエラーになっても、コネクション自体は確立される

### checkout と checkin
- checkout = プールから1本借りる(busy が +1)
- checkin = プールに返す(busy が -1, idle が +1)
- 返しても切断はされない(idle として待機)
- Rails のコントローラーでは ActiveRecord が自動で checkout/checkin する

### メインスレッドの特性
- 一度 checkout した接続を持ち続ける(自動返却されない)
- だから素のスクリプトでは busy=1 のまま見える
- Web リクエストとは挙動が違うので注意-

## dead と checkout_timeout
{... dead: 0, ..., checkout_timeout: 2.0}
dead: 「壊れた電話の数」。何らかの理由で使えなくなった接続(DB側で切られた、ネットワーク切断など)。
健康な状態では 0。
checkout_timeout: これはカウントじゃなくて設定値。
「電話を借りようとして空いていない時、何秒まで待つか」のタイムアウト時間。2.0 秒が設定されている。
これを超えて待たされると ConnectionTimeoutError が出る。

## pool.stat キー一覧

### 各キーの意味

| キー | 主語 | 意味 | 図書館の比喩 |
|------|------|------|-------------|
| `size` | 枠 | プールが持てる電話の最大本数(設定値) | 棚の容量(最大5冊置ける) |
| `connections` | 電話 | 今までに実際に繋いだ電話の本数 | 実際に買った本の数 |
| `busy` | 電話 | 使用中の電話の本数 | 貸出中の本 |
| `idle` | 電話 | 空いている電話の本数(返却済み・待機中) | 棚にある本 |
| `waiting` | 人 | 電話が空くのを待っている人の数 | 行列に並んでいる利用者 |
| `dead` | 電話 | 壊れた電話の本数(切断された接続など) | 破損した本 |
| `checkout_timeout` | 設定値 | 電話を借りる時の最大待ち時間(秒) | 「○秒待っても無理ならエラー」のしきい値 |

### 重要な関係式

busy + idle = connections        # 実在する電話は必ず「使用中」か「空き」のどちらか
connections ≦ size               # 実在する電話は最大本数を超えない
waiting > 0 → プール枯渇のサイン  # 待ち人数が出る = 電話が足りていない

## 学習チェックポイント
- [ ] pool.stat の各キーの意味が言える
- [ ] connections と busy の違いが説明できる
- [ ] なぜ「遅延生成」されるのか分かる