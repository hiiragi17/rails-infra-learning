# Step 2: スレッド競合と checkout 待ち

実行日:
環境: macOS / Ruby 3.4.2 / SQLite

---

## 02_checkout_race.rb

### 実行前の予想

設定条件: pool size = 3、checkout_timeout = 1秒、スレッド5本、各スレッドが3秒間 sleep

| 項目 | 予想 | 理由 |
|------|------|------|
| waiting の最大値 | 2 | 5本中3本は即 checkout できて、残り2本が待つから |
| エラーは出るか | 出る（ConnectionTimeoutError） | waiting の2本が1秒待っても返ってこないから |
| `busy + idle = connections` は競合中も成り立つか | 成り立つ | waiting はまだ借りられていないので式に登場しないから |

### 実際の出力
```
bundle exec ruby 02_checkout_race.rb
-- create_table(:users)
-> 0.0047s
=== 設定 ===
pool: 2, threads: 5, sleep: 1s, timeout: 3s

[14:13:32.034] [#0] checkout成功 (wait=0.0s) busy=2 waiting=4
[14:13:33.052] [#0] checkin
[14:13:33.052] [#1] checkout成功 (wait=1.02s) busy=2 waiting=3
[14:13:34.056] [#1] checkin
[14:13:34.057] [#2] checkout成功 (wait=2.02s) busy=2 waiting=2
[14:13:35.039] [#3] タイムアウト: could not obtain a connection from the pool within 3.000 seconds (waited 3.005 se
[14:13:35.040] [#4] タイムアウト: could not obtain a connection from the pool within 3.000 seconds (waited 3.005 se
[14:13:35.062] [#2] checkin

=== 終了後の pool.stat ===
{size: 2, connections: 2, busy: 1, dead: 0, idle: 1, waiting: 0, checkout_timeout: 3.0}

■ 観察ポイント
- 最初の2本はwait=0で成功
- それ以降のスレッドはwaitが1秒以上になる
- waiting の数字が動く

■ 試してほしい変更
- CHECKOUT_TIMEOUT=1, SLEEP_DURATION=2 にすると ConnectionTimeoutError が出る
- POOL_SIZE=5 にすれば全員wait=0で成功する
```

### 予想とのズレ

- waiting の最大値を「2」と予想したが、実際は「4」だった
- 理由：メインスレッドがすでに1本 checkout していたため、
　スレッド #0〜#4 が使える枠は実質1本しかなかった

### 気づいたこと・疑問

メインスレッド  → create_table などで checkout → busy=1
スレッド #0     → checkout → busy=2  ← 満杯！
スレッド #1〜#4 → 全員 waiting に並ぶ → waiting=4

---

## 02b_leak.rb（コネクションリーク編）

## 実行前の予想

| 項目 | NGパターン | OKパターン |
|------|-----------|-----------|
| busy の変化 | 増え続けて2で詰まる | 1→0→1→0… と行き来する |
| idle の変化 | 増えない | 最後 idle=2 で終わる |
| 3本目・4本目 | タイムアウトエラー | 問題なく成功 |

### 実際の出力

```
bundle exec ruby 02b_leak.rb
-- create_table(:users)
   -> 0.0054s
=== ❌ NGパターン: Thread内で直接クエリ。連続で叩くとリークする ===
[#0] スレッド終了後 stat={size: 2, connections: 2, busy: 1, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}
[#1] スレッド終了後 stat={size: 2, connections: 2, busy: 1, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}
[#2] スレッド終了後 stat={size: 2, connections: 2, busy: 1, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}
[#3] スレッド終了後 stat={size: 2, connections: 2, busy: 1, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}

=== ✅ OKパターン: with_connection で囲む ===
[#0] スレッド終了後 stat={size: 2, connections: 1, busy: 0, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}
[#1] スレッド終了後 stat={size: 2, connections: 1, busy: 0, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}
[#2] スレッド終了後 stat={size: 2, connections: 1, busy: 0, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}
[#3] スレッド終了後 stat={size: 2, connections: 1, busy: 0, dead: 0, idle: 1, waiting: 0, checkout_timeout: 1.0}

■ 観察ポイント
- NGパターンでは busy が増え続け、最終的にプール枯渇する
- Railsのリクエストでは Rack ミドルウェアが自動 checkin してくれる
- 自前でThreadを立てるバッチや非同期処理では with_connection が必須
```

### 予想とのズレ

NGで「busy が増え続けて2で詰まる」と予想したが、実際は busy=1 のままだった

理由: ActiveRecord 7.2 では with_connection を使わなくてもクエリ終了時点で自動返却されるようになっていた
古いバージョン（Rails 5以前）では確実にリークしていた


OKで「最後 idle=2 になる」と予想したが、実際は idle=1 のままだった

理由: with_connection が1本のコネクションを使い回すため、connections=1 で足りた


### 気づいたこと・疑問

-リークは ActiveRecord のバージョンで挙動が変わる。今回は再現できなかったが、古いバージョンや常駐ワーカースレッド（Sidekiq など）では今でも起きる
- NGとOKの本質的な違いは数字に出た： 
  - NG: connections=2（メインスレッド分も含めて2本貼られる、無駄がある） 
  - OK: connections=1（1本だけ使い回す、無駄がない）
- with_connection を使うとコネクションの使用を最小限に抑えられる


【プール枯渇】一時的な問題

全スレッドが busy → waiting に並ぶ
↓
誰かが checkin する
↓
waiting の人が checkout できる → 解消される

【コネクションリーク】じわじわ悪化する問題

checkin されないコネクションが増え続ける
↓
idle が永遠に増えない
↓
新しいリクエストが waiting に並ぶ
↓
誰も checkin しないので待ち続ける → タイムアウトエラー
↓
アプリを再起動するまで直らない

## 学習チェックポイント

- [ ] `waiting > 0` の状態を実際に目で見た
- [ ] `ConnectionTimeoutError` のエラーメッセージを確認した
- [ ] `busy + idle = connections` が競合中も成り立つことを出力で確認した
- [ ] 「プール枯渇」と「コネクションリーク」の違いを自分の言葉で説明できる