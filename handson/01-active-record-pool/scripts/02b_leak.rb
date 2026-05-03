# 02b_leak.rb
# Step 2 発展: with_connection の有無でコネクションの使い方がどう変わるかを観察
#
# 実行: bundle exec ruby 02b_leak.rb
# 前提: rm -f /tmp/ar_playground.db を先に実行すること
#
# 【注意】このスクリプトは元々「リークを再現する」目的で書かれていたが、
# ActiveRecord 7.2 ではクエリ終了時に自動返却されるようになったため、
# リーク自体は再現できなかった。
# 代わりに「with_connection あり/なし でコネクション数がどう違うか」を観察する。

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  # :memory: だとスレッド間でDBが共有されず "Could not find table" エラーになるため
  # ファイルDBに変更。実行前に rm -f /tmp/ar_playground.db で古いファイルを消すこと。
  database: "/tmp/ar_playground.db",
  pool: 2,
  checkout_timeout: 1
)

ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base; end

pool = ActiveRecord::Base.connection_pool

puts "=== ❌ NGパターン: with_connection を使わない ==="
# with_connection を使わずに Thread.new で直接クエリを叩く。
# ActiveRecord 7.2 ではクエリ終了時に自動返却されるため、リーク自体は起きない。
# ただしメインスレッドの分も含めて connections=2 になる（無駄が出る）。

threads = []

4.times do |i|
  t = Thread.new do
    begin
      puts "[##{i}] create! 開始"
      User.create!(name: "leaked-#{i}")
      puts "[##{i}] create! 完了、sleep開始"
      sleep 10
    rescue => e
      puts "[##{i}] スレッド内エラー: #{e.class} #{e.message}"
    end
  end
  sleep 0.5  # スレッドが checkout するのを少し待つ
  threads << t
  puts "[##{i}] スレッドは生きているか: #{t.alive?}"
  puts "[##{i}] stat=#{pool.stat}"
end

threads.each(&:join)  # 最後にまとめて待つ

puts
puts "=== ✅ OKパターン: with_connection で囲む ==="
# with_connection { } で囲むと、ブロック終了時に自動 checkin される。
# プール内の1本を使い回すため connections=1 で済む（無駄がない）。

# プールをリセット
pool.disconnect!

4.times do |i|
  Thread.new do
    pool.with_connection do
      User.create!(name: "ok-#{i}")
    end
    # ブロック終了時に自動 checkin される
  end.join
  puts "[##{i}] stat=#{pool.stat}"
end

puts
puts "■ 観察ポイント"
puts "- NGパターン: connections=2（メインスレッド分も含めて余分に貼られる）"
puts "- OKパターン: connections=1（1本を使い回すので無駄がない）"
puts "- with_connection を使うとコネクションの使用を最小限に抑えられる"
puts "- 自前でThreadを立てるバッチや非同期処理では with_connection が必須"