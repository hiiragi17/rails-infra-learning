# Webアプリケーションサーバー学習ノート

## 概要

Webアプリケーションサーバーの構成、HTTP通信、REST設計、セキュリティ、AWSインフラについての学習メモ。

---

## 1. サーバーの全体構成

リクエストは以下の順序で処理される。

```
ブラウザ → HTTPS (SSL/TLS) → Nginx → ALB → ECS (Rails コンテナ)
```

### Webサーバー (Nginx)

- port 80 (HTTP) / 443 (HTTPS) でリクエストを受ける
- 役割: 静的ファイル配信、リバースプロキシ、（ロードバランサー）
- L7ルーティング、アクセスコントロール、アクセスログの管理
- 静的ファイルはNginxで返す方がアプリサーバーを通すより高速
- 設定変更時はbuildプロセスが必要（CircleCIでWebヘッダー設定なども管理）

### アプリケーションサーバー (Rails)

- リクエストを受けてレスポンスを返すのがサーバーの基本的な役割
- Railsがビジネスロジックを処理し、レスポンスを生成する

### Nginx と ALB の関係

- 「ロードバランサー」は役割の総称、ALBはAWSの具体的なサービス
- Nginxにもロードバランサー機能はあるが、AWS構成ではALBに任せてNginxはリバースプロキシ・静的配信に専念するのが一般的
- ALBはECSタスクへの振り分け・ヘルスチェックを担当

---

## 2. HTTP通信

### プロトコルとポート

| プロトコル | ポート | 特徴 |
|-----------|-------|------|
| HTTP | 80 | 暗号化なし、高速、低コスト |
| HTTPS | 443 | SSL/TLSで暗号化 |
| localhost | 3000, 3001 など | 開発環境ではポート指定 |

### HTTPメソッド

| メソッド | 用途 | データの送り方 | 備考 |
|---------|------|--------------|------|
| GET | リソースの取得 | `?key=value` クエリパラメーター | bodyなし / URIに長さ上限あり / 最もよく使われる |
| POST | データの送信・新規作成 | リクエストbody | encoding: form-data / JSON / multipart |
| PUT | リソースの完全な置き換え | リクエストbody | updateのみ、createには使わない |
| PATCH | リソースの部分更新 | リクエストbody | 変更したいフィールドだけ送る |
| DELETE | リソースの削除 | 通常bodyなし | 指定したリソースを削除 |

### GETリクエストのクエリパラメーター

- URLの末尾に `?key=value` で渡す。複数は `&` でつなぐ
- 例: `GET /agents?status=active&page=2&per_page=20`
- bodyが使えないため、データはすべてURLに載せる
- URIの長さ上限は実用上2,048文字程度。大量データはPOSTに切り替える
- 日本語や特殊文字はパーセントエンコーディング（URLエンコーディング）される
- ブックマーク可能でキャッシュも効く（冪等性がある）
- Railsでは `params[:key]` でアクセス（パスパラメーターと同じhashに入る）

### リクエストヘッダー

- `Content-Type`: データ形式の指定（`application/json`, `text/html`, `text/plain`, `multipart/form-data`）
- `Accept`: レスポンスで受け取りたい形式を指定
- `Cookie`: セッション情報
- `Authorization` / APIトークン: 認証情報
- CSRFトークン: セキュリティ用
- ファイルアップロード時は `multipart/form-data`（バウンダリーで本文とファイルを区切る）

### レスポンスのステータスコード

#### 2xx — 成功

| コード | 名前 | 意味 |
|-------|------|------|
| 200 | OK | リクエスト成功 |
| 201 | Created | リソースの新規作成に成功（POST時） |
| 204 | No Content | 成功したがbodyなし（DELETE成功時） |

#### 3xx — リダイレクト

| コード | 名前 | 意味 |
|-------|------|------|
| 301 | Moved Permanently | 恒久的なURL変更（SEOに影響） |
| 302 | Found | 一時的なリダイレクト（Railsのredirect_toのデフォルト） |
| 304 | Not Modified | キャッシュをそのまま使ってOK |

#### 4xx — クライアントエラー

| コード | 名前 | 意味 |
|-------|------|------|
| 400 | Bad Request | リクエストが不正（パラメーター不足など） |
| 401 | Unauthorized | 認証されていない（ログインしていない / トークン切れ） |
| 403 | Forbidden | 認証済みだがアクセス権限なし |
| 404 | Not Found | リソースが存在しない |
| 422 | Unprocessable Entity | バリデーションエラー（Railsの定番） |
| 429 | Too Many Requests | レートリミット超過 |

#### 5xx — サーバーエラー

| コード | 名前 | 意味 |
|-------|------|------|
| 500 | Internal Server Error | サーバー内部エラー（バグ・未処理の例外） |
| 502 | Bad Gateway | Nginxがアプリサーバーに接続できない |
| 503 | Service Unavailable | デプロイ中・メンテナンス・過負荷 |
| 504 | Gateway Timeout | アプリサーバーが応答タイムアウト |

覚え方: 先頭の数字で判断。2xx=成功、3xx=リダイレクト、4xx=クライアントが悪い、5xx=サーバーが悪い。

---

## 3. REST設計

### 基本思想

すべてを「リソース（resource）」として捉える。URLは「何に対して」、HTTPメソッドは「何をするか」を表現する。

### RESTful ルーティング（Railsの `resources :agents`）

| メソッド | URL | action | 用途 |
|---------|-----|--------|------|
| GET | /agents | index | 一覧取得 |
| GET | /agents/:id | show | 個別取得 |
| GET | /agents/new | new | 新規作成フォーム |
| GET | /agents/:id/edit | edit | 編集フォーム |
| POST | /agents | create | 新規作成 |
| PUT | /agents/:id | update | 全体更新 |
| PATCH | /agents/:id | update | 部分更新 |
| DELETE | /agents/:id | destroy | 削除 |

CRUD対応: Create=POST, Read=GET, Update=PUT/PATCH, Delete=DELETE

### パスパラメーター vs クエリパラメーター

| 種類 | 例 | 用途 |
|-----|-----|------|
| パスパラメーター | `/agents/10` | 特定リソースの指定（IDで一意に特定） |
| クエリパラメーター | `/agents?status=active&page=2` | フィルター・条件・ソート・ページネーション |

### RESTのルールと現実

- RESTは規約であり技術的に強制はされない（POSTでデータ取得もコード上は可能）
- ただしルールに従うことでURLから動作が推測でき、チーム開発での認識ずれが減る
- 厳密な会社ではコードレビューやlintルールでREST違反を弾く
- ネストは2階層まで（例: `GET /agents/10/tasks`）
- CRUDに当てはまらない操作（ログイン、CSVエクスポート等）はカスタムアクションで対応

---

## 4. セキュリティ

### SSL/TLS

- HTTPS通信を実現する暗号化プロトコル
- ハンドシェイクで暗号化方式を合意 → 暗号化通信が開始
- 鍵の長さ（key長）とアルゴリズムで暗号強度が決まる
- 短い鍵は判別が容易 → 現在は長い鍵が標準（SSL証明書で確認可能）
- 暗号化にはコストがかかる（プライベートネットワーク内ではHTTPの方が高速・低コスト）

### SQLインジェクション

- IDしか入らないところに文字列を入れてSQL文が成り立ってしまう攻撃
- Railsではプレースホルダーやパラメータライズドクエリで対策

### ブルートフォース攻撃

- パスワードの総当たり攻撃。時間をかければいつかは解ける
- 暗号化の鍵長（例: 256bit）で解読難易度が変わる

---

## 5. AWSインフラ構成

### ECS (Elastic Container Service)

```
ECS Cluster → Service（複数） → Task（最小単位 = コンテナ）
```

- Clusterが最上位の論理グループ
- Serviceが複数のTaskを管理
- Taskが実際のDockerコンテナ（= Railsアプリサーバー）

### ECR (Elastic Container Registry)

- Dockerイメージの保管場所
- Dockerfileに基づいてビルドしたイメージをpush
- ECSはECRからイメージを取得してコンテナを起動

### ALB (Application Load Balancer)

- L7のロードバランサー
- ECSタスクへのリクエスト振り分け・ヘルスチェック

### デプロイフロー

```
コード変更 → CircleCI → Docker build → ECR push → ECS タスク起動
```

---

## 6. 用語整理

| 用語 | 説明 |
|------|------|
| URI / URL | リソースの識別子。URLはURIの一種で、アクセス方法（プロトコル）を含む |
| リバースプロキシ | クライアントとサーバーの間に入り、リクエストを中継する |
| ロードバランサー | 複数サーバーにリクエストを分散する仕組みの総称 |
| Content-Type | リクエスト/レスポンスのデータ形式を示すヘッダー |
| multipart/form-data | ファイルアップロード時の形式。バウンダリーで本文とファイルを区切る |
| 冪等性 | 同じリクエストを何度送っても同じ結果になる性質（GETは冪等） |
