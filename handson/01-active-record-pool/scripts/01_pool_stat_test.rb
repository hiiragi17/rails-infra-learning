require "active_record"

# DB接続の設定だけする(create_tableはしない)
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:",
  pool: 5
)

# まだ何もしていない状態
puts ActiveRecord::Base.connection_pool.stat
# → {size: 5, connections: 0, ...}  ← まだ0!

# クエリを叩く(テーブルがなくても、SQLそのものは投げられる)
ActiveRecord::Base.connection.execute("SELECT 1")

puts ActiveRecord::Base.connection_pool.stat
# → {size: 5, connections: 1, busy: 1, ...}  ← 1本繋がった!