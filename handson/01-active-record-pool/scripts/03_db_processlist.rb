# 03_db_processlist.rb
# Step 3: Rails側のpool.statとDB側のprocesslistを突き合わせて見る
#
# 事前準備:
#   docker run -d --name ar-mysql \
#     -e MYSQL_ROOT_PASSWORD=pass \
#     -e MYSQL_DATABASE=playground \
#     -p 3306:3306 \
#     mysql:8
#
# 起動を待つ:
#   docker logs -f ar-mysql
#   ("ready for connections" が出たらCtrl+Cで抜ける)
#
# 実行: bundle exec ruby 03_db_processlist.rb

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "mysql2",
  host: "127.0.0.1",
  port: 3306,
  username: "root",
  password: "pass",
  database: "playground",
  pool: 5,
  checkout_timeout: 5
)

ActiveRecord::Schema.define do
  drop_table :users, if_exists: true
  create_table :users do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base; end

pool = ActiveRecord::Base.connection_pool

def show_db_side
  rows = ActiveRecord::Base.connection.execute(<<~SQL)
    SELECT id, user, db, command, time, state
    FROM information_schema.processlist
    WHERE db = 'playground'
    ORDER BY id
  SQL

  puts "  --- DB側のprocesslist (db=playground) ---"
  rows.each do |row|
    puts "  id=#{row[0]} user=#{row[1]} command=#{row[3]} time=#{row[4]}s state=#{row[5]}"
  end
  puts "  conn数: #{rows.count}"
end

def show_rails_side(pool)
  stat = pool.stat
  puts "  --- Rails側のpool.stat ---"
  puts "  size=#{stat[:size]} connections=#{stat[:connections]} busy=#{stat[:busy]} idle=#{stat[:idle]} waiting=#{stat[:waiting]}"
end

puts "=== ① 起動直後 ==="
show_rails_side(pool)
show_db_side

puts
puts "=== ② 3スレッドで並行クエリ実行中 ==="

log_mutex = Mutex.new

threads = 3.times.map do |i|
  Thread.new do
    pool.with_connection do
      User.create!(name: "user-#{i}")
      sleep 3   # この間にメインスレッドが状態を覗く
    end
  end
end

# スレッドがcheckoutし終わるまで少し待つ
sleep 0.5

show_rails_side(pool)
show_db_side

puts
puts "  💡 別ターミナルで以下を実行すると、リアルタイムでDBを覗けます:"
puts %{     docker exec -it ar-mysql mysql -uroot -ppass -e "SHOW PROCESSLIST;"}

threads.each(&:join)

puts
puts "=== ③ 全スレッド終了後 ==="
show_rails_side(pool)
show_db_side

puts
puts "■ 観察ポイント"
puts "- ② の時点で Rails側 busy=3、DB側 conn数=4 (3本 + メインスレッド分)"
puts "- ③ の時点では Rails側は idle に戻るが、DB側のconnは残る (idle接続)"
puts "- これは「使い回す」ためにわざと切らずに置いてある"
puts "- 切りたい時は pool.disconnect! を呼ぶ、または idle_timeout を設定する"

puts
puts "後片付け: docker stop ar-mysql && docker rm ar-mysql"
