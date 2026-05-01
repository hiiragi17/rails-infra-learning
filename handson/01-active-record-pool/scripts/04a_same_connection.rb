# 04a_same_connection.rb
# 課題A: トランザクションは同一connで実行されることを実証
#
# 実行: bundle exec ruby 04a_same_connection.rb

require "active_record"

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

puts "=== ① transactionブロックの中では同じconn ==="
User.transaction do
  puts "1回目: conn.object_id = #{ActiveRecord::Base.connection.object_id}"
  User.create!(name: "a")

  puts "2回目: conn.object_id = #{ActiveRecord::Base.connection.object_id}"
  User.create!(name: "b")

  puts "3回目: conn.object_id = #{ActiveRecord::Base.connection.object_id}"
end
# 期待: すべて同じobject_id

puts
puts "=== ② 別スレッドでは別conn ==="
User.transaction do
  main_id = ActiveRecord::Base.connection.object_id
  puts "メインスレッド: conn.object_id = #{main_id}"

  thread = Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do
      sub_id = ActiveRecord::Base.connection.object_id
      puts "別スレッド:   conn.object_id = #{sub_id}"
      puts "→ 同じか? #{main_id == sub_id}"
    end
  end
  thread.join
end
# 期待: メインと別スレッドで違うobject_id
# → だから「別スレッドで作ったレコードはトランザクションの外」

puts
puts "■ 観察ポイント"
puts "- transactionブロック内ではconnが固定される"
puts "- 別スレッドは別connなので、トランザクションの効果は及ばない"
puts "- これが Sidekiq enqueue がロールバックされない理由 (→ 04b で実演)"
