# Step 4c: ActiveSupport::Notifications で SQL を購読する

実行日: 2026-05-03
環境: macOS / Ruby 3.4.2 / SQLite (`:memory:`)

---

## このスクリプトで何を確かめるのか

- Rails が裏で投げている SQL を **リアルタイムにログ出力** する
- `User.create!` のような ActiveRecord メソッドが、実は **複数の SQL に展開されている** ことを目で見る
- `User.transaction do ... end` の挙動を SQL レベル(BEGIN/COMMIT/ROLLBACK)で観察する
- → これが Bullet / rack-mini-profiler / New Relic などの**APMツールの土台技術**

---

## なぜ学ぶ価値があるか

### Rails のブラックボックスを開ける鍵

04bまでは「実行結果」を見ていただけ:
- 04a: connection.object_id で「同じconnか?」を確認
- 04b: 最終的にテーブルに何が残ったかで結果確認

→ どちらも「終わった後の状態」しか見えていない

04cでは「実行中に Rails が何をしているか」を直接覗く。

### この仕組み(ActiveSupport::Notifications)は現場の主役

| ツール | 何をする | 購読するイベント |
|--------|---------|-----------------|
| Bullet | N+1検出 | sql.active_record |
| rack-mini-profiler | リクエストごとのSQL一覧 | sql.active_record |
| New Relic / Datadog | APM性能監視 | 各種 |
| lograge | ログ整形 | process_action.action_controller |

→ Railsの可観測性ツール群の**共通インフラ**。これを知っていると Rails 力が一段上がる。

---

## 事前準備: create と create! の違い

ここでようやく整理した重要な前提:

| | `create` | `create!` |
|---|---------|----------|
| 失敗時 | 静かに失敗(戻り値で判断) | 例外を投げる |
| 戻り値 | User オブジェクト(persisted?で判定) | (成功時のみ User、失敗時は例外) |
| 主な用途 | コントローラー(画面で再表示) | サービス層・テスト・ハンズオン |

- ハンズオンで `create!` を使ってきたのは **「失敗を例外で大声で知らせるため」**
- 04bで `raise "intentional rollback"` で ROLLBACK を起こせたのも、`create!` の例外伝搬と同じ仕組み
- Ruby の `!` は「危険・破壊的な動作」を示す慣習(String#upcase! も元の文字列を書き換える)

---

## ActiveSupport::Notifications とは

- Rails 標準装備の **イベント通知の仕組み**(Pub/Sub パターン)
- 「特定のイベントが起きたら、登録した処理を呼ぶ」
- `subscribe(イベント名)` で購読、Rails が内部で `instrument(イベント名)` で発火
- `sql.active_record` を購読すれば、全SQLが流れてくる
- production でも使えるが、オーバーヘッドに注意

```ruby
ActiveSupport::Notifications.subscribe('sql.active_record') do |name, start, finish, id, payload|
  # payload[:sql] に実行された SQL 文字列が入っている
end
```

---

## 実行前の予想と結果の照合

### ケース① `User.count`

**予想:**
- SQL: `SELECT COUNT(*) FROM users`
- トランザクションは出ない(読み取りだけだから)

**実際:**
```
[SQL] PRAGMA table_xinfo("users")
[SQL] SELECT sql FROM (SELECT * FROM sqlite_master ...)
[SQL] SELECT COUNT(*) FROM "users"
```

**照合:**
- ✅ `SELECT COUNT(*) FROM users` は予想通り
- ✅ トランザクションが出ていないのも予想通り
- ⚠️ 前に2つの謎SQLが先行した

**気づき:**
- 先行するSQLは ActiveRecord のテーブル情報の事前取得(初回のみ)
- 「`users` テーブルって何カラムある? どんな型?」を内部で確認している
- これがプロジェクト起動時に走るので、テーブル数が多いと起動が遅くなる原因になる

---

### ケース② `User.create!(name: "Alice")` ⭐ 一番大事

**予想:**
- SQL: `INSERT INTO users(name) VALUES('Alice')`
- トランザクションはない(成功するから)

**実際:**
```
[SQL] (テーブル情報の事前取得 × 3)
[SQL] begin transaction        ← ⭐
[SQL] INSERT INTO "users" ("name") VALUES (?) RETURNING "id"
[SQL] commit transaction       ← ⭐
[TX]  outcome=commit
```

**照合:**
- ✅ INSERT 文は予想通り
- ❌ **「トランザクションはない」は外れ!**
    - 実は **暗黙のトランザクション(BEGIN-INSERT-COMMIT)** で囲まれていた

**気づき:**
- **`User.create!` は内部で BEGIN→INSERT→COMMIT の3ステップを発行している**
- 理由: ActiveRecord のコールバック(after_save, after_create)で失敗したら巻き戻せるように、関連テーブルへの同時INSERTがあっても安全になるように
- → **データを変更する処理(INSERT/UPDATE/DELETE)は、たとえ1回でも、必ずトランザクションで囲まれる**
- コードは1行、でも SQL は3つ。「裏で勝手に3倍働いている」

---

### ケース③ `User.transaction do User.create!(Bob); User.create!(Carol) end`

**予想:**
```
BEGIN
INSERT (Bob)
INSERT (Carol)
COMMIT
```

**実際:**
```
[SQL] begin transaction
[SQL] INSERT INTO "users" ... (Bob)
[SQL] INSERT INTO "users" ... (Carol)
[SQL] commit transaction
[TX]  outcome=commit
```

**照合:**
- ✅ **完全に予想通り!**

**気づき:**
- ケース②と比較すると、`transaction` で囲むと **複数のINSERTが1セットのBEGIN/COMMITにまとまる**
- もし `transaction` で囲まずに `create!` を2回呼ぶと、**BEGIN/COMMITが2セット発生する**(ケース②が2回繰り返される)
- → `transaction do ... end` は整合性だけでなく、**BEGIN/COMMITのオーバーヘッドを減らす性能上のメリット**もある

---

### ケース④ `User.transaction do User.create!(Dave); raise end`

**予想:**
```
BEGIN
INSERT (Dave)
ROLLBACK
COMMIT     ← ここがズレ
```

**実際:**
```
[SQL] begin transaction
[SQL] INSERT INTO "users" ... (Dave)
[SQL] rollback transaction
[TX]  outcome=rollback
```

**照合:**
- ✅ BEGIN, INSERT, ROLLBACK は予想通り
- ❌ **COMMIT は出なかった**

**気づき:**
- **ROLLBACK と COMMIT は排他**: どちらか一方しか出ない、両方は出ない
- トランザクションの基本ルール: BEGIN → 成功なら COMMIT / 失敗なら ROLLBACK で取引を終わらせる
- 「終わりには COMMIT が必要」という思い込みが外れた瞬間
- ROLLBACKが「終わり」の役割も果たしている

---

## 観察された全体の構造

```
User.count  ┐
            ├─ SELECT のみ → トランザクション不要
User.where  ┘

User.create!  ┐
User.update!  ├─ 暗黙のトランザクション(BEGIN-COMMIT)で1つずつ囲まれる
User.destroy! ┘

User.transaction do
  User.create!  ┐
  User.create!  ├─ まとめて1つのトランザクション
  User.create!  ┘
end

User.transaction do
  User.create!     ─ 例外発生
  raise            → BEGIN-INSERT-ROLLBACK で終わる(COMMIT は出ない)
end
```

---

## 04b への伏線回収

04b では「メインが ROLLBACK した、別スレッドの INSERT は残った」という現象を観察した。
04c で SQL レベルで見ると、実際にはこういう SQL が流れていたことが分かる:

```
メインのconn:
BEGIN
INSERT (origin='main_thread')
ROLLBACK     ← これが実際にDBに送られていた!

別スレッドのconn:
BEGIN
INSERT (origin='sub_thread')
COMMIT       ← 別connで完結した独立トランザクション
```

04b では「結果として残ったかどうか」しか見えなかったが、
04c の購読技術により「実際にDBに送られたSQL」がリアルタイムで観察できる。

---

## 確認クイズで定着

### 問題
次のコード(初回起動後)を実行したら、どんな SQL が流れる?

```ruby
User.create!(name: "Alice")
User.create!(name: "Bob")
```

### 答え
**B: BEGIN, INSERT(Alice), COMMIT, BEGIN, INSERT(Bob), COMMIT**

### 理由
`create!` は暗黙的にトランザクションが貼られているため、1回ごとに BEGIN/COMMIT が発生する。

### 現場での応用
1000件のデータ投入を `create!` ループで書くと、BEGIN/COMMIT が1000セット発生して激遅になる。
`User.transaction do ... end` で囲むと1セットにまとまり、劇的に速くなる。
(さらに本気で速くしたい場合は `User.insert_all` で1SQLにまとめる方法もある)

---

## 応用: これを使って何ができるか

### N+1検出の作り方(Bullet の最小実装)

```ruby
queries = []
ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
  queries << payload[:sql]
end

# リクエスト処理...

similar_count = queries.group_by(&:itself).map { |_, v| v.size }.max
puts "WARNING: 同じSQL が #{similar_count}回 走っています(N+1の可能性)" if similar_count > 5
```

### スロークエリ検出

```ruby
ActiveSupport::Notifications.subscribe('sql.active_record') do |_, start, finish, _, payload|
  duration_ms = (finish - start) * 1000
  if duration_ms > 100
    Rails.logger.warn "SLOW SQL: #{duration_ms}ms | #{payload[:sql]}"
  end
end
```

### 本番で気をつけること
- subscribe したブロックは**全SQLで呼ばれる**ので、重い処理を入れるとアプリ全体が遅くなる
- 集計データはメモリに溜め込みすぎない
- production では条件付きで有効化することが多い

---

## 学習チェックポイント

- [x] `sql.active_record` を購読すると全SQLが取れることを実機で確認した
- [x] `User.create!` が内部で BEGIN→INSERT→COMMIT を発行することを確認した(最大の発見)
- [x] `User.transaction` を明示的に使うと、複数のINSERTが1つのトランザクションにまとまることを確認した
- [x] ROLLBACK が SQL として送られることを確認した
- [x] COMMIT と ROLLBACK は排他であることを確認した
- [x] テーブル情報の事前取得SQLが初回に走ることを確認した
- [x] Bullet や APM の動作原理が言語化できる
- [x] `transaction do ... end` で囲むことが整合性だけでなく性能にもメリットがあることを説明できる(クイズ正解)

---

## Step 4 全体のまとめ(04a → 04b → 04c の振り返り)

| Step | 観察方法 | 何が分かった |
|------|---------|-------------|
| 4a | connection.object_id を比較 | 同じスレッド=同じconn / 別スレッド=別conn(理論) |
| 4b | テーブルの残レコード | 別connのINSERTはROLLBACKをすり抜ける(現象) |
| 4c | SQLイベントを購読 | Railsが裏で投げてるSQLを実機で観察(実装) |

→ **「conn の概念」→「現象として見える」→「実装として見える」** と階層を降りた

### 全体を貫く理解

- ActiveRecord はスレッド単位でconnを管理し、同じスレッドなら同じconnを返す
- DBはconn(セッション)単位でトランザクション状態を持つ
- `create!` などのデータ変更操作は暗黙のトランザクションで囲まれる
- 別スレッド = 別conn = 別セッション = 別トランザクション
- → これらが組み合わさって、Sidekiq enqueue 問題のような実務バグを生む

### 次に進むとき(Step 5以降)に役立つこと
- 04c の購読技術は、Step 5(OS視点での観察)・Step 6(tcpdump)と組み合わせると強力
- 例: SQLイベント発火と TCP パケット送信のタイミングを比較できる
- Rails内部 → OS → ネットワーク の観察スタックが一通り揃う