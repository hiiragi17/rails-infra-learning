# 06_tcpdump_handshake.rb
# Step 6: Rails が DB に接続する瞬間のパケットを tcpdump で捕まえる
#
# このスクリプトは MySQL に1回だけ接続して切断します。
# その時に走る TCP 3way handshake と MySQL認証パケットを観察します。
#
# 事前準備:
#   1. MySQLが立ち上がっていること(03と同じ)
#   2. tcpdump が使えること
#
# 実行手順:
#   ターミナル1で先に tcpdump を起動:
#     sudo tcpdump -i lo0 -nn 'port 3306' -A    # macOS
#     sudo tcpdump -i lo  -nn 'port 3306' -A    # Linux
#
#     # より詳しく見るなら -vvv -X (バイナリ込み)
#     sudo tcpdump -i lo  -nn 'port 3306' -vvv -X
#
#   ターミナル2でこのスクリプトを実行:
#     bundle exec ruby 06_tcpdump_handshake.rb

require "active_record"

puts "5秒後に接続します。今のうちに別ターミナルで tcpdump を起動してください..."
puts
puts "  Linux:  sudo tcpdump -i lo  -nn 'port 3306' -A"
puts "  macOS:  sudo tcpdump -i lo0 -nn 'port 3306' -A"
puts
5.downto(1) do |i|
  print "\r  接続まで#{i}秒..."
  sleep 1
end
puts "\n"

puts "=== TCP接続を開始 ==="
ActiveRecord::Base.establish_connection(
  adapter: "mysql2",
  host: "127.0.0.1",
  port: 3306,
  username: "root",
  password: "pass",
  database: "playground"
)

# 接続を実際に貼るため、軽くクエリを発行
ActiveRecord::Base.connection.execute("SELECT 1")
puts "→ 接続成立 + 認証 + クエリ完了"
sleep 1

puts
puts "=== 切断 ==="
ActiveRecord::Base.connection_pool.disconnect!
puts "→ FIN パケットが飛ぶ"
sleep 1

puts
puts "■ tcpdump で見えるはずのもの"
puts "1. SYN, SYN-ACK, ACK    ← TCPの3way handshake"
puts "2. MySQLサーバーからのGreeting (バージョン番号などが見える)"
puts "3. クライアントからの認証情報 (username等)"
puts "4. サーバーからのOKパケット"
puts "5. SELECT 1 のクエリ本文 (-A で文字列として見える)"
puts "6. 結果セット"
puts "7. FIN, ACK             ← 切断"
puts
puts "■ 観察ポイント"
puts "- MySQLプロトコルは平文 (TLSなしの場合)、パスワードはハッシュ化されるが他は丸見え"
puts "- だからAuroraにつなぐ時は SSL/TLS が推奨される"
puts "- Ctrl+Cでtcpdumpを止めて、出力を読んでみてください"
