# 04b_transaction_leak.rb (MySQL版)
# 課題B: トランザクションをすり抜けるバグの再現
#
# 実行: bundle exec ruby 04b_transaction_leak.rb
#
# Sidekiqジョブをトランザクション内でenqueueすると、
# ロールバックしてもジョブは消えない、という有名なバグの正体。
#
# ※ SQLite版だと "database is locked" でロック衝突するため、MySQLで再現する。
#   MySQLは行ロックなので、別connが同時に同じテーブルにINSERTしても通る。
#
# 前提: Finchコンテナ ar-mysql が起動していること
#   finch start ar-mysql

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "mysql2",
  host: "127.0.0.1",
  port: 3306,
  username: "root",
  password: "pass",
  database: "playground",
  pool: 5
)

ActiveRecord::Schema.define do
  drop_table :users, if_exists: true
  create_table :users do |t|
    t.string :name
    t.string :origin   # どこで作られたか記録
  end
end

class User < ActiveRecord::Base; end

User.delete_all

puts "=== トランザクション内で別スレッドからINSERT、その後ロールバック ==="

begin
  User.transaction do
    User.create!(name: "main", origin: "main_thread")
    puts "[main] 'main' を作成"

    # 別スレッドから別のレコードをINSERT
    # ※ 普通はやらない。Sidekiq.enqueueが内部で別connを使う様子を擬似的に再現
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.create!(name: "subthread", origin: "sub_thread")
        puts "[sub]  'subthread' を作成 (別conn)"
      end
    end.join

    # 例外を投げてロールバック
    puts "[main] 例外を発生させてロールバックします"
    raise "intentional rollback"
  end
rescue => e
  puts "[main] catch: #{e.message}"
end

puts
puts "=== 結果 ==="
User.all.each do |u|
  puts "残ったレコード: id=#{u.id} name=#{u.name} origin=#{u.origin}"
end

puts
puts "■ 観察ポイント"
puts "- メインスレッドの 'main' はロールバックで消える"
puts "- 別スレッドの 'subthread' は残る (別connなので別トランザクション扱い)"
puts "- Sidekiq.perform_async は内部でこれと似た挙動をする"
puts "  → 対策: after_commit コールバック内で enqueue する"

# 後片付け: SQLiteのファイル削除は不要。テーブルだけ残しておけば次回 drop_table で消える