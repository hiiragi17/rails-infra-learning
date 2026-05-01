# 02_checkout_race.rb
# Step 2: スレッド競合で checkout 待ちが発生する様子を観察
#
# 実行: bundle exec ruby 02_checkout_race.rb
#
# このスクリプトの設定値を変えて、いろいろ試してみてください。

require "active_record"

# === 実験パラメータ ===
POOL_SIZE        = 2   # プールに何本conn置くか
CHECKOUT_TIMEOUT = 3   # conn待ちの最大秒数
THREAD_COUNT     = 5   # 同時に起動するスレッド数
SLEEP_DURATION   = 1   # 各スレッドが conn を占有する時間(秒)
# ====================

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:",
  pool: POOL_SIZE,
  checkout_timeout: CHECKOUT_TIMEOUT
)

ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base; end

pool = ActiveRecord::Base.connection_pool

# 出力が混ざらないようにロック
log_mutex = Mutex.new
def log(mutex, msg)
  mutex.synchronize { puts "[#{Time.now.strftime('%H:%M:%S.%L')}] #{msg}" }
end

puts "=== 設定 ==="
puts "pool: #{POOL_SIZE}, threads: #{THREAD_COUNT}, sleep: #{SLEEP_DURATION}s, timeout: #{CHECKOUT_TIMEOUT}s"
puts

threads = THREAD_COUNT.times.map do |i|
  Thread.new do
    started_at = Time.now
    begin
      pool.with_connection do |conn|
        wait = (Time.now - started_at).round(2)
        stat = pool.stat
        log(log_mutex, "[##{i}] checkout成功 (wait=#{wait}s) busy=#{stat[:busy]} waiting=#{stat[:waiting]}")

        sleep SLEEP_DURATION
        # 何かクエリを実行(ここで conn を実際に使う)
        User.count

        log(log_mutex, "[##{i}] checkin")
      end
    rescue ActiveRecord::ConnectionTimeoutError => e
      log(log_mutex, "[##{i}] タイムアウト: #{e.message[0..80]}")
    end
  end
end

threads.each(&:join)

puts
puts "=== 終了後の pool.stat ==="
p pool.stat

puts
puts "■ 観察ポイント"
puts "- 最初の#{POOL_SIZE}本はwait=0で成功"
puts "- それ以降のスレッドはwaitが#{SLEEP_DURATION}秒以上になる"
puts "- waiting の数字が動く"
puts
puts "■ 試してほしい変更"
puts "- CHECKOUT_TIMEOUT=1, SLEEP_DURATION=2 にすると ConnectionTimeoutError が出る"
puts "- POOL_SIZE=#{THREAD_COUNT} にすれば全員wait=0で成功する"
