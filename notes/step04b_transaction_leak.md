# Step 4b: トランザクションすり抜けバグ(Sidekiq enqueue 問題の本質)

実行日: 2026-05-03
環境: macOS / Ruby 3.4.2 / MySQL (Finch コンテナ ar-mysql)
※ 当初SQLiteで実行したがロック衝突で失敗。MySQLに切り替えて成功。

---

## このスクリプトで何を確かめるのか

- トランザクションブロック内で **別スレッドから** INSERT した場合、
  メインがROLLBACKしてもそのレコードが**消えない**ことを目で見る
- 04a で言語化した「別スレッド=別conn=トランザクション外」が、
  プロダクションでどう悪さするかを実機で再現する
- → これが本番Rails+Sidekiq構成で起きる **典型バグ** の本質

---

## なぜ学ぶ価値があるか

### Sidekiq enqueue 問題の典型コード

```ruby
def create
  ActiveRecord::Base.transaction do
    user = User.create!(params)              # ① ユーザー作成
    WelcomeMailerJob.perform_async(user.id)  # ② Sidekiqにジョブ投入
  end
end
```

このコードに潜む2種類の問題:
1. **タイミング問題**: COMMIT前にWorkerがRedisから取り出して`User.find(id)` → NotFound
2. **整合性問題**: メインがROLLBACKされても、Sidekiqに登録したジョブは消えない
   → 「存在しないユーザー」にメール送信しようとする

### 04bで確かめるのは「整合性問題」のミニ版

Sidekiqの代わりに「別スレッドで直接INSERT」で再現する。
本質は同じ:**別conn(別セッション)からのINSERTは、メインのROLLBACKに巻き込まれない**

---

## 事前知識(Step 4aから引き継いでいる理解)

- 同じスレッド = 同じconn (object_id 同じ)
- 別スレッド = 別conn (object_id 違う)
- ActiveRecord は Thread.current ベースで conn を管理している
- DBは「コネクション(セッション)単位」でトランザクション状態を持つ
- 別connからのクエリは、メインのトランザクションとは別の独立した取引としてコミットされる

---

## 実行前の予想

### 質問
スクリプト実行後、テーブルに残るレコードはどれか?

予想する答え: subスレッドのものが残る

理由(自分の言葉で):
別スレッドからINSERTされているので、メインのトランザクションとは違うスレッド(=別conn)のため。
トランザクション内のmainのものはロールバックされて消えて、
別スレッドのsubthreadは残ると考えられる。

---

## SQLite版で起きたエラー(最初に踏んだ想定外)

### 起きたこと
最初は SQLite (`leak_test.db`) で実行 → `SQLite3::BusyException: database is locked` 発生。
別スレッドの `User.create!` がエラーで落ちた。

### なぜ起きたか
- SQLite は **DBファイル全体をロック** する仕組み
- メインがトランザクション中(BEGIN→INSERT後、COMMIT/ROLLBACK前)に
  別connから書き込もうとすると、ロック衝突して BusyException
- MySQL/PostgreSQL は **行ロック** なので、こういう衝突は起きにくい

### この想定外から得た学び
- このエラー自体が「別スレッド = 別conn = 別セッション」の証拠
    - もし同じconnなら、そもそもロック衝突しない(同じセッション内のINSERT扱い)
- 04bの「ROLLBACKされても残る」現象を見るには **MySQLの方が向いている**
- SQLiteはテストや学習用には便利だが、並行書き込みの再現には不向き
- → 同じ現象を再現するDBによって、見え方が変わることがある

---

## 実際の出力 (MySQL版)

```
mami.hirono@fcl0044 scripts % bundle exec ruby 04b_transaction_leak.rb
-- drop_table(:users, {if_exists: true})
   -> 0.0151s
-- create_table(:users)
   -> 0.0049s
=== トランザクション内で別スレッドからINSERT、その後ロールバック ===
[main] 'main' を作成
[sub]  'subthread' を作成 (別conn)
[main] 例外を発生させてロールバックします
[main] catch: intentional rollback

=== 結果 ===
残ったレコード: id=2 name=subthread origin=sub_thread
```

---

## 気づいたこと・疑問

### 予想とのズレ
- 予想: subthreadだけが残る
- 実際: **予想通り。id=2 のレコードだけが残った**
- 理由: 予想と一致(別conn = 別セッション = メインのROLLBACK対象外)

### 興味深い発見: id が 2 から始まっている
- id=1 が存在しない**歯抜け状態**
- これは「id=1 はメインスレッドで一度発番されたが、ROLLBACKで消えた」という証拠
- MySQLのAUTO_INCREMENTは、**ロールバックされてもカウンタが戻らない仕様**
- → プロダクションで id が飛び飛びの場合、過去にロールバックがあった可能性

### このバグが「気づきにくい」理由
- コード上は `Thread.new do ... end` がトランザクションブロックの「中」にあるので、
  プログラマには「ブロック内の処理」に見える
- しかし実行時には別conn=別セッションで動くので、メインのトランザクションには含まれない
- → **コードの見た目と実行時の振る舞いがズレる**

### Sidekiq.perform_async との対応関係
- 別スレッドの `User.create!` = Sidekiqの「ジョブをRedisに書き込む」処理
- メインのROLLBACK = create! が失敗してトランザクション巻き戻し
- → ROLLBACK後、Redisにはジョブだけ残る
- → Workerがそのジョブを処理しようとして「対応するUserがいない!」とエラー

---

## 確認クイズで身についた応用力

### 問題
`Thread.new` を外して、同じメインスレッドの中で2回 `User.create!` を呼んだ場合、
ROLLBACKしたらレコードはどうなる?

```ruby
User.transaction do
  User.create!(name: "main", origin: "main_thread")
  User.create!(name: "subthread", origin: "main_thread_inside")  # ← 同じスレッドで作る
  raise "intentional rollback"
end
```

### 答え
**両方消える**

### 理由
- どちらも同じスレッドなので、ActiveRecordのルールにより同じconnを使う
- 同じconnは同じセッション → 両方ともメインのトランザクションに含まれる
- ROLLBACKで両方消える

### この問題が解けた意味
- 「同じスレッド = 同じconn」(04a のルール)
- 「同じconn の中ならトランザクションが効く」(04b で確認した帰結)
- この2つを組み合わせて、**未知のケースの結果を予測できるようになった**

---

## 対策について(調べる)

### `after_commit` コールバックを使う

```ruby
class User < ApplicationRecord
  after_commit :send_welcome_email, on: :create
  
  private
  def send_welcome_email
    WelcomeMailerJob.perform_async(id)
  end
end
```

- `after_commit` は**トランザクションがCOMMITされた後**に実行される
- ROLLBACKされた場合は呼ばれない
- → 「ユーザー作成が確定したら初めてジョブ投入」が保証される

### Rails 7.1+ の `enqueue_after_transaction_commit`

- ActiveJob 自体に「トランザクションコミット後にenqueueする」機能が追加された
- `config.active_job.enqueue_after_transaction_commit = :always` で有効化

### `transactional_outbox` パターン

- ジョブ情報を一旦自分のDBの outbox テーブルに書き込み、別プロセスがそれを読んで Redis に流す
- DBへの書き込みなのでトランザクションに含まれる
- マイクロサービスでよく使われる本格的な対策

---

## DB側からの観察(発展課題)

スクリプト実行と並行して、別ターミナルで PROCESSLIST を観察すれば、
2つの conn(=2セッション)が並行して動いている様子が見えるはず。

```bash
while true; do
  clear
  finch exec -i ar-mysql mysql -uroot -ppass -e "SHOW PROCESSLIST;" 2>/dev/null
  sleep 0.2
done
```

(スクリプトが一瞬で終わるので、観察は難しいかもしれない。
04c の SQL購読の方がリアルタイムに動きを追える。)

---

## 学習チェックポイント

- [x] `:memory:` ではなくファイルDB(またはMySQL)を使う理由が説明できる
- [x] 別スレッドのINSERTがROLLBACKされない現象を実機で再現できた
- [x] このバグが「コード見た目と実行時挙動のズレ」から生まれることを言語化できる
- [x] Sidekiq.perform_async との対応関係が説明できる
- [x] `after_commit` で対策できる理由が説明できる
- [x] AUTO_INCREMENT がロールバックでも戻らないことを id=2 の事実から知った
- [x] 同じスレッド内なら2回INSERTでも両方ROLLBACKされることが説明できる(クイズ正解)

---

## 次のステップ(04c)への伏線

04cでは、ActiveSupport::Notifications を使って、
今まで「object_id」や「rescueの結果」でしか見えていなかった内部の挙動を
**SQL購読という形で直接観察**する。

具体的には:
- メインスレッドで「BEGIN → INSERT → ROLLBACK」がどう発行されているか
- 別スレッドの「INSERT」はメインのBEGINの外で動いているのか
- → これらをリアルタイムにログとして見える化

04bで「結果として残ったかどうか」しか見ていなかった現象を、
04cでは**実行中の SQL ログ** として観察できる。
04bの理解をさらに一段強化する位置づけ。

これは Bullet や APM(New Relic, Datadog 等)が
内部で使っている仕組みでもある。