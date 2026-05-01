# 01_pool_stat.rb
# Step 1: ConnectionPool の状態を pool.stat で覗く
#
# 実行: bundle exec ruby 01_pool_stat.rb

require "active_record"

# SQLiteのインメモリDBに接続。プールは5本まで。
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:",
  pool: 5,
  checkout_timeout: 2
)

# シンプルなテーブルを作る
ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base; end

pool = ActiveRecord::Base.connection_pool

def show(label, pool)
  puts "--- #{label} ---"
  p pool.stat
  puts
end

show("起動直後 (まだクエリを叩いていない)", pool)
# 期待: connections: 0, busy: 0
# → conn は遅延生成。最初のクエリで初めて貼られる

User.create!(name: "Alice")
show("1回クエリを叩いた直後", pool)
# 期待: connections: 1。クエリ後すぐに checkin されるので busy: 0, idle: 1

# 手動で checkout してみる
conn = pool.checkout
show("手動 checkout した状態", pool)
# 期待: busy: 1, idle: 0
# → conn を借りっぱなし。誰かに貸している状態

pool.checkin(conn)
show("checkin で返却した後", pool)
# 期待: busy: 0, idle: 1
# → 返却された。次のクエリでこの conn が再利用される

puts "■ 観察ポイント"
puts "- 起動直後は connections=0 (遅延生成)"
puts "- クエリ後 connections は 1 になり、idleに戻る"
puts "- checkout → busy が増え、checkin → idle に戻る"
puts "- size は設定値(5)、connections は実際に貼られた本数"
