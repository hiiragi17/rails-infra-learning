# 07_fd_limit.rb
# Step 7: コネクション = ファイルディスクリプタ であることを確認、
# ulimit に当てて壊してみる
#
# 実行: bundle exec ruby 07_fd_limit.rb
#
# 別ターミナルで以下を観察:
#   ls -la /proc/<PID>/fd/         (Linuxのみ)
#   lsof -p <PID> | wc -l
#   cat /proc/<PID>/limits | grep "open files"  (Linux)

require "active_record"

pid = Process.pid

ActiveRecord::Base.establish_connection(
  adapter: "mysql2",
  host: "127.0.0.1",
  port: 3306,
  username: "root",
  password: "pass",
  database: "playground",
  pool: 100,             # 大きめに設定
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

# 現在のfd数を取得
def count_fds(pid)
  if File.directory?("/proc/#{pid}/fd")
    Dir.children("/proc/#{pid}/fd").size
  else
    # macOS など /proc が無い環境
    `lsof -p #{pid} 2>/dev/null | wc -l`.to_i
  end
end

# ulimit -n の確認
soft_limit = `ulimit -Sn`.to_i rescue nil

puts "=" * 60
puts "PID: #{pid}"
puts "ulimit -n (soft): #{soft_limit || '取得失敗'}"
puts "起動直後のfd数: #{count_fds(pid)}"
puts "=" * 60
puts
puts "🔍 別ターミナルで以下を実行すると詳しく見れます:"
puts "  Linux: ls -la /proc/#{pid}/fd/ | head -20"
puts "  両OS: lsof -p #{pid} -a -i TCP | wc -l"
puts
puts "Enterで開始..."
gets

# 段階的にコネクションを増やしていく
[1, 5, 10, 30, 50].each do |n|
  conns = []
  n.times do
    conns << pool.checkout
    # 軽くクエリを叩いて実際にソケットを開く
    conns.last.execute("SELECT 1")
  end

  fd_count = count_fds(pid)
  puts "checkout #{n}本: pool.connections=#{pool.stat[:connections]}, OS fd数=#{fd_count}"

  # 全部checkin
  conns.each { |c| pool.checkin(c) }
end

puts
puts "■ 観察ポイント"
puts "- conn を1本貼るたびに OSのfdが1つ増える"
puts "- pool.disconnect! を呼ぶか、プロセス終了で初めてfdは解放される"
puts
puts "■ 試してみてほしい実験"
puts "1. ulimit -n 20 で起動して pool=30 にすると fd 不足で死ぬ"
puts "   $ ulimit -n 20"
puts "   $ bundle exec ruby 07_fd_limit.rb"
puts "   → 'Too many open files' エラーが出る"
puts "2. これがプロダクションでよくある『なぜか接続できない』の原因"
puts
puts "■ プロダクションでの目安"
puts "- ulimit -n は最低でも 65536 にしておくのが定石"
puts "- systemd なら LimitNOFILE=65536"
puts "- Docker なら --ulimit nofile=65536:65536"

pool.disconnect!
