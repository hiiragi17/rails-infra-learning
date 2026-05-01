# 02b_leak.rb
# Step 2 発展: with_connection を使わないと conn がリークする様子
#
# 実行: bundle exec ruby 02b_leak.rb
#
# このスクリプトは「やってはいけない例」です。
# Thread を生で立てて、conn の返却を意識しないとどうなるかを示します。

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:",
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

puts "=== ❌ NGパターン: Thread内で直接クエリ。連続で叩くとリークする ==="

# 4本のスレッドを起動。各スレッドが conn を1本掴むが、
# Thread終了時に自動checkinされない (Rackミドルウェアがないので)
4.times do |i|
  Thread.new do
    User.create!(name: "leaked-#{i}")
    # ここで conn が紐付いたまま、明示的に開放しない
    # → スレッド終了後も conn はプールに戻らない
  end.join
  puts "[##{i}] スレッド終了後 stat=#{pool.stat}"
end

puts
puts "=== ✅ OKパターン: with_connection で囲む ==="

# プールをリセット
pool.disconnect!

4.times do |i|
  Thread.new do
    pool.with_connection do
      User.create!(name: "ok-#{i}")
    end
    # ブロック終了時に自動 checkin される
  end.join
  puts "[##{i}] スレッド終了後 stat=#{pool.stat}"
end

puts
puts "■ 観察ポイント"
puts "- NGパターンでは busy が増え続け、最終的にプール枯渇する"
puts "- Railsのリクエストでは Rack ミドルウェアが自動 checkin してくれる"
puts "- 自前でThreadを立てるバッチや非同期処理では with_connection が必須"
