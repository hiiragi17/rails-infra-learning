# Step 4a: トランザクションは同一connで実行されることを実証

実行日: 2026-05-03
環境: macOS / Ruby 3.4.2 / SQLite (`:memory:`)

## このスクリプトで何を確かめるのか

- トランザクションブロックの中では、複数のクエリが**同じコネクション**から流れていることを目で見る
- 別スレッドからアクセスすると、それは**別のコネクション**になることを目で見る
- → これが Step 4b で扱う「Sidekiq enqueue がロールバックされない」バグの土台になる

## 事前知識(自分で言語化したもの)

### なぜ「同一コネクション保証」が必要か
- もしトランザクション内のクエリがバラバラのconnから流れたら、整合性が壊れる
    - 例: 銀行振替で「Aから引く」と「Bに足す」が別connから流れて、ROLLBACKが効かない
- DBはコネクション(=セッション)ごとにトランザクション状態を持つので、
  「BEGINとINSERTがペアかどうか」をコネクション以外で判断できない

### `ActiveRecord::Base.connection` とは
- 「現在のスレッドが借りているコネクション」を返す
- `object_id` を比較すれば、同じconnか違うconnか判別できる

---

## 実行前の予想

### 質問①
`User.transaction do ... end` ブロックの中で `User.create!` を3回呼んだとき、
それぞれの `ActiveRecord::Base.connection.object_id` は同じになるか、違うか。

答え: 同じになる

理由:　同じトランザクション内だから

予想する出力:
```
1回目: conn.object_id = 同じ
2回目: conn.object_id = 同じ
3回目: conn.object_id = 同じ
```

### 質問②
トランザクションブロックの中で、別スレッドが `with_connection` で接続を借りたとき、
そのスレッドが見る `connection.object_id` はメインスレッドと同じか、違うか。

答え:同じ

理由:同じじゃないと整合性が取れないと思ったから

予想する出力:
```
メインスレッド: conn.object_id = 同じ
別スレッド:   conn.object_id = 同じ
→ 同じか? ?????
```

---

## 実際の出力

```
bundle exec ruby 04a_same_connection.rb
-- create_table(:users)
   -> 0.0057s
=== ① transactionブロックの中では同じconn ===
1回目: conn.object_id = 816
2回目: conn.object_id = 816
3回目: conn.object_id = 816

=== ② 別スレッドでは別conn ===
メインスレッド: conn.object_id = 816
別スレッド:   conn.object_id = 928
→ 同じか? false

■ 観察ポイント
- transactionブロック内ではconnが固定される
- 別スレッドは別connなので、トランザクションの効果は及ばない
- これが Sidekiq enqueue がロールバックされない理由 (→ 04b で実演)
```

---

## 気づいたこと・疑問

### 予想とのズレ
- 予想: 別スレッドでも同じconn(整合性のため)
- 実際: 別スレッドは別conn(object_id=928)
- 理由: ActiveRecord は Thread.current ベースで conn を管理しているから。
  「整合性のために同じconnになる」のではなく、
  「同じconnを使わないと整合性が保てない(=書く人の責任)」が正しい因果関係。

### わかったこと
「同じスレッド = 同じconn」「別スレッド = 別conn」 という ActiveRecord のルール
「整合性のために同じconnになる」は誤り。正しくは「同じconnを使わないと整合性が保てない(プログラマの責任)」
ActiveRecord が Thread.current ベースでconnを管理する設計の理由(混線防止)
構文上のブロック(コードの見た目)と、実行時の振る舞い(どのconnで動くか)はズレることがある

## 「同一コネクション保証」をRailsはどう実現しているか(調べてみる)

ActiveRecord は内部で `Thread.current` ベースでコネクションを管理している。
- 同じスレッドからの `ActiveRecord::Base.connection` は同じconnを返す
- 別スレッドからの `ActiveRecord::Base.connection` は別のconnを返す(= プールから別の1本を借りる)
- トランザクションブロックの中では、そのスレッドのconnが固定される

→ つまり「同一コネクション保証 = 同一スレッド保証」と言い換えてもいい

## 学習チェックポイント

- [ ] トランザクションブロック内ではconnが固定されることを実証できた
- [ ] 別スレッドは別connを使うため、トランザクションの効果が及ばないことを確認した
- [ ] `connection.object_id` で「同じconnか違うconnか」を判別する方法を知った
- [ ] 04b の「Sidekiq enqueue 問題」が予想できる: 「Sidekiqのworkerは別プロセス/別スレッドだから、
  enqueueしたジョブのレコードはトランザクションの外で作られる」という仮説が立てられる

## 04b への予想(クイズの答え)

問: transactionブロック内で、メインと別スレッドの両方からINSERTした後、
メインがROLLBACKしたらテーブルに何件残るか?

答え: 1件(別スレッドで作ったレコードのみ残る)

理由:
- メインのROLLBACKは「メインが借りているconn(=同じセッション)」の取引を巻き戻すだけ
- 別スレッドは別conn(=別セッション)からINSERTしているので、
  そのINSERTはMySQLからは独立した取引としてコミット済み
- だから「メインのROLLBACK」と「別スレッドのINSERT」は無関係
- これが Sidekiq enqueue 問題の本質と予想する