# 04c_notifications.rb
# 課題C: ActiveSupport::Notifications でSQLとトランザクションを購読
#
# 実行: bundle exec ruby 04c_notifications.rb
#
# Bullet, rack-mini-profiler, NewRelic などが裏で使っているのがこの仕組み。

require "active_record"
require "active_support/notifications"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:",
  pool: 5
)

ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base; end

# === 全SQLを購読 ===
ActiveSupport::Notifications.subscribe('sql.active_record') do |name, start, finish, id, payload|
  duration_ms = ((finish - start) * 1000).round(2)
  sql = payload[:sql].gsub(/\s+/, ' ')[0..100]
  puts "  [SQL] #{duration_ms}ms | #{sql}"
end

# === トランザクション開始/終了を購読 ===
# (Rails 7.1+)
ActiveSupport::Notifications.subscribe('transaction.active_record') do |name, start, finish, id, payload|
  duration_ms = ((finish - start) * 1000).round(2)
  puts "  [TX]  #{duration_ms}ms | outcome=#{payload[:outcome] || 'committed'}"
end

puts "=== シンプルなSELECT ==="
User.count

puts
puts "=== INSERT ==="
User.create!(name: "Alice")

puts
puts "=== トランザクション (commit) ==="
User.transaction do
  User.create!(name: "Bob")
  User.create!(name: "Carol")
end

puts
puts "=== トランザクション (rollback) ==="
begin
  User.transaction do
    User.create!(name: "Dave")
    raise "rollback"
  end
rescue => e
  puts "  rescued: #{e.message}"
end

puts
puts "■ 観察ポイント"
puts "- すべてのSQLが横から見える"
puts "- BEGIN / COMMIT / ROLLBACK もログに出る"
puts "- これを集計すれば「N+1検出」「スロークエリ検出」「APMツール」が作れる"
puts "- subscribe は production でも使える。ただしオーバーヘッドに注意"
