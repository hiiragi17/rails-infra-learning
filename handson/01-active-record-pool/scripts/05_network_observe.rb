# 05_network_observe.rb
# Step 5: Rails側のpool.statと、OS側のソケット情報を突き合わせる
#
# 事前準備: 03_db_processlist.rb と同じくMySQLが必要
#   docker run -d --name ar-mysql \
#     -e MYSQL_ROOT_PASSWORD=pass \
#     -e MYSQL_DATABASE=playground \
#     -p 3306:3306 \
#     mysql:8
#
# 実行: bundle exec ruby 05_network_observe.rb
#
# このスクリプトは「自分のPID」を表示します。
# 別ターミナルで以下のコマンドを叩いて、OS側からも観察してください:
#
#   # macOS / Linux 両対応
#   lsof -p <PID> | grep TCP
#
#   # Linux のみ (より高速・詳細)
#   ss -tnp | grep <PID>
#   ss -tn 'dport = :3306'
#
#   # macOS のみ
#   netstat -an | grep 3306
#   lsof -i :3306

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
pid = Process.pid

puts "=" * 60
puts "このプロセスのPID: #{pid}"
puts "=" * 60
puts
puts "🔍 別ターミナルを開いて、以下のコマンドを試してください:"
puts
puts "  Linux:"
puts "    ss -tnp | grep #{pid}"
puts "    lsof -p #{pid} -a -i TCP"
puts
puts "  macOS:"
puts "    lsof -p #{pid} | grep TCP"
puts
puts "  両方共通:"
puts "    docker exec ar-mysql mysql -uroot -ppass -e 'SHOW PROCESSLIST'"
puts
puts "Enter を押すと進みます..."
gets

puts
puts "=== ① 起動直後 (まだクエリ叩いてない) ==="
puts "Rails側 stat: #{pool.stat}"
puts "→ ここでOS側を見ると、3306へのTCP接続は無いはず"
puts "  (connections: 0 = まだ実際のソケットを開いていない)"
puts
puts "Enter で次へ..."
gets

puts "=== ② 1回クエリ実行 ==="
User.count
puts "Rails側 stat: #{pool.stat}"
puts "→ OS側を見ると、3306へのESTABLISHED接続が1本見えるはず"
puts "  プロセスがソケットを1つ開いた = fd を1つ消費した"
puts
puts "Enter で次へ..."
gets

puts "=== ③ 3スレッド並行で長めのクエリ実行中 ==="
threads = 3.times.map do |i|
  Thread.new do
    pool.with_connection do
      ActiveRecord::Base.connection.execute("SELECT SLEEP(8)")
    end
  end
end

sleep 0.5
puts "Rails側 stat: #{pool.stat}"
puts "→ OS側を見ると、3306へのESTABLISHED接続が増えているはず"
puts "  busy=3 と TCP接続数が一致するか確認"
puts
puts "今のうちに別ターミナルで観察を!"
puts "(8秒スリープ中)"

threads.each(&:join)

puts
puts "=== ④ 全スレッド終了後 ==="
puts "Rails側 stat: #{pool.stat}"
puts "→ Rails側は busy=0 になるが、OS側のESTABLISHED接続はまだ残っているはず"
puts "  これがコネクションの「使い回し」の正体"
puts
puts "Enter で接続を明示的に切る..."
gets

pool.disconnect!
puts "=== ⑤ pool.disconnect! 実行後 ==="
puts "Rails側 stat: #{pool.stat}"
puts "→ OS側のESTABLISHED接続も消える(またはTIME_WAIT/CLOSE_WAIT状態に)"
puts
puts "■ 観察ポイントまとめ"
puts "1. Rails の connections数 = OS の3306へのTCP接続数"
puts "2. クエリを叩いていない時もコネクションは開きっぱなし(idle)"
puts "3. pool.disconnect! でカーネルがソケットをcloseする"
puts "4. close後しばらくTIME_WAIT状態が残る (TCPの仕様)"
