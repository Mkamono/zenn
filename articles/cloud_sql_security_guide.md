---
title: "「完璧」は存在しない。「最適」を選べ。Cloud SQLセキュリティ設計"
emoji: "🛡️"
type: "tech"
topics: ["googlecloud", "cloudsql", "security", "iam", "networking"]
published: false
---

## はじめに

Cloud SQLは、Google Cloud上で提供されるフルマネージドなRDBサービスです。多くのサービスで採用されており、その利便性とスケーラビリティは非常に魅力的です。

Cloud SQLのセキュリティ設計について調べていると、「Private Google Access」「VPC Service Controls」「IAM Database Authentication」など、様々な技術用語に出会います。どれも重要そうに見えますが、実際のところ**あなたのプロジェクトにはどこまで必要なのでしょうか？**

「セキュリティは万全にしておくべきだ」と思って最高レベルの構成を目指すと、複雑さと運用コストに圧倒されます。一方で「とりあえず動けばいい」という考えでは、本番環境で取り返しのつかないインシデントを招く可能性があります。

この記事では、Cloud SQLのセキュリティ対策を**4つのレベル**に整理し、あなたのプロジェクトの要件に応じて「最適な構成」を選択できるガイドを提案します。

完璧なセキュリティは存在しません。しかし、あなたのプロジェクトにとって「最適」なセキュリティレベルは必ず見つけることができます。

## セキュリティレベルの全体像

以下の4つのレベルで段階的にセキュリティを強化していきます：

- **Level 0**: すべての基本となる「認証」の近代化
- **Level 1**: 開発のスタートライン（パブリックIP + 承認済みネットワーク）
- **Level 2**: モダンな基本形（パブリックIP + Cloud SQL Auth Proxy）
- **Level 3**: 本番環境のベストプラクティス（プライベートIP + IAP）
- **Level 4**: 究極のゼロトラスト（プライベートIP + VPC Service Controls）

## 【Level 0】すべての基本となる「認証」の近代化

ネットワーク構成を考える前に、まず基本中の基本を押さえておきましょう。「誰が」「何が」データベースに接続するのか、その認証方法を見直すことです。実は、多くのセキュリティ事故はパスワードやサービスアカウントキーの漏洩から始まります。

### 原則1：パスワードの撲滅 - IAMデータベース認証

従来のパスワード認証では、パスワードを定期的にローテーションしたり、アプリケーションの設定ファイルに埋め込んだりする必要がありました。しかし、これらの管理は煩雑で、しかも漏洩リスクが常につきまといます。

IAMデータベース認証では、Google CloudのIAMユーザーやサービスアカウントとして認証を行います。短時間だけ有効なアクセストークンを取得してDBにログインするため、パスワードを管理する必要がありません。

```bash
# 従来の方法（避けるべき）
mysql -h [IP] -u myuser -p
# パスワードを入力...

# IAMデータベース認証
gcloud sql connect my-instance --user=myuser@mydomain.com
# Google CloudのIAM認証で自動ログイン
```

**メリット**
- 認証情報をコードや設定ファイルに埋め込む必要がない
- IAMで一元的に権限を管理できる
- 監査証跡もIAMと統合される
- パスワードローテーションが不要

### 原則2：サービスアカウントキーの撲滅 - Workload Identity連携

GitHubで「service-account.json」を検索してみてください。おそらく大量の秘密鍵ファイルが見つかるはずです。これらのファイルは一度流出すると、攻撃者があなたのGoogle Cloudリソースに自由にアクセスできてしまいます。

Workload Identity連携では、GitHub ActionsやGitLabなどの外部サービスが、OIDCというプロトコルを使ってGoogle IAMに「私は正規のCI/CDです」と証明します。その結果、秘密鍵ファイルを保存することなく、短時間有効なトークンを取得できます。

```yaml
# GitHub ActionsでのWorkload Identity連携例
- name: 'Authenticate to Google Cloud'
  uses: 'google-github-actions/auth@v1'
  with:
    workload_identity_provider: 'projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/my-provider'
    service_account: 'my-service@my-project.iam.gserviceaccount.com'

- name: 'Connect to Cloud SQL'
  run: |
    gcloud sql connect my-instance --user=my-service@my-project.iam.gserviceaccount.com
```

**メリット**
- 秘密鍵ファイルが不要になる（これが最大のメリット）
- 認証情報漏洩のリスクを劇的に低減
- 認証情報のローテーションが自動化される

## 【Level 1】開発のスタートライン：パブリックIP + 承認済みネットワーク

### 構成概要

Cloud SQLインスタンスにパブリックIPアドレスを割り当て、「承認済みネットワーク」機能で接続元IPアドレスを制限する最もシンプルな構成です。

```
[開発者PC] ---> [インターネット] ---> [Cloud SQL (パブリックIP)]
              特定のIPアドレスのみ許可
```

### 設定方法

```bash
# Cloud SQLインスタンスの作成（パブリックIP有効）
gcloud sql instances create my-instance \
    --database-version=MYSQL_8_0 \
    --tier=db-f1-micro \
    --assign-ip

# 承認済みネットワークの追加
gcloud sql instances patch my-instance \
    --authorized-networks=203.0.113.0/24
```

### このレベルが解決する課題

「とにかく早く開発を始めたい」「難しい設定は後回しにしたい」そんな時の出発点です。インターネット上の無差別攻撃は防げますが、それ以上の脅威には対応できません。

### リスク分析：防御できる攻撃と残存する脅威

**防御できる攻撃**
- **無差別なスキャン攻撃**: インターネット全体から行われる、無作為なIPアドレスに対するパスワード総当たり攻撃

**しかし、このような脅威は防げません**
- **オフィスWi-Fiが乗っ取られた場合**: 許可されたIPアドレスからの攻撃は素通りしてしまいます
- **データベースエンジンに脆弱性が見つかった場合**: インターネットに公開されているため、直接攻撃される可能性があります
- **設定ミス**: うっかり `0.0.0.0/0` を設定してしまうと、全世界に公開されてしまいます
- **リモートワーク**: IPアドレスが頻繁に変わる環境では、管理が追いつかなくなります

### このレベルでの認証

- **人間のアクセス**: 学習目的でDBネイティブのパスワード認証を使うことも可能ですが、この段階からIAMデータベース認証に慣れておくことを強く推奨
- **アプリケーションのアクセス**: このレベルでは通常、アプリからの本格的な接続は想定しません

### 適用場面

- 個人学習・プロトタイプ開発
- 固定IPアドレスを持つ開発環境
- セキュリティ要件が低いテスト環境

## 【Level 2】モダンな基本形：パブリックIP + Cloud SQL Auth Proxy

### 構成概要

Cloud SQL Auth Proxyを使用することで、暗号化された安全な接続と、IAMベースの認証を実現します。

```
[アプリケーション] ---> [Cloud SQL Auth Proxy] ---> [Cloud SQL (パブリックIP)]
                    暗号化 + IAM認証
```

### 設定方法

```bash
# Cloud SQL Auth Proxyのダウンロード
curl -o cloud_sql_proxy https://dl.google.com/cloudsql/cloud_sql_proxy.linux.amd64
chmod +x cloud_sql_proxy

# プロキシの起動
./cloud_sql_proxy -instances=my-project:asia-northeast1:my-instance=tcp:3306
```

アプリケーションからの接続：

```python
# Python例
import sqlalchemy

# ローカルのプロキシ経由で接続
engine = sqlalchemy.create_engine('mysql+pymysql://user@localhost:3306/db')
```

### このレベルが解決する課題

「IPアドレスの管理から解放されたい」「どこからでも安全に接続したい」そんな要望に応える構成です。多くの本番環境で採用されている、現実的なバランスの取れた選択肢と言えるでしょう。

### リスク分析：防御できる攻撃と残存する脅威

**防御できる攻撃**
- **Level 1の全ての脅威**（DBエンジンの脆弱性攻撃、IPベースの攻撃など）
- **通信の盗聴**: Auth Proxyは常にTLSで通信を暗号化するため、中間者攻撃（MITM）から保護される

**しかし、このような脅威は防げません**
- **認証情報が盗まれた場合**: 開発者のPCがマルウェアに感染したり、サービスアカウントキーが流出したりすると、攻撃者は世界中どこからでもDBに接続できてしまいます
- **データの持ち出し**: 一度認証を突破されると、攻撃者のマシンから直接DBにアクセスできるため、データの大量流出を防ぐ手段がありません

### このレベルでの認証

- **人間のアクセス**: IAMデータベース認証を標準とする。これにより、Auth Proxyによる強力な認証・暗号化が実現される
- **アプリケーションのアクセス**: Cloud RunやApp Engineから接続する場合、それらのサービスに紐づくサービスアカウントのIDで接続。Workload Identity連携は、CI/CDパイプラインからDBマイグレーションを実行する際などに極めて有効

### 適用場面

- 多くの本番環境での標準構成
- マルチクラウドやオンプレミスからの接続
- 開発チームが分散している環境

## 【Level 3】本番環境のベストプラクティス：プライベートIP + IAP

### 構成概要

Cloud SQLにプライベートIPのみを割り当て、Identity-Aware Proxy（IAP）を通じてセキュアなアクセスを実現します。

```
[開発者] ---> [IAP] ---> [踏み台サーバー] ---> [Cloud SQL (プライベートIP)]
            Google認証    VPC内部           VPC内部接続
```

### 設定方法

```bash
# VPCとサブネットの作成
gcloud compute networks create my-vpc --subnet-mode=custom
gcloud compute networks subnets create my-subnet \
    --network=my-vpc \
    --range=10.0.0.0/24 \
    --region=asia-northeast1

# プライベートサービス接続の設定
gcloud compute addresses create google-managed-services-my-vpc \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=16 \
    --network=my-vpc

gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-my-vpc \
    --network=my-vpc

# プライベートIP付きCloud SQLインスタンスの作成
gcloud sql instances create my-instance \
    --database-version=MYSQL_8_0 \
    --tier=db-f1-micro \
    --network=my-vpc \
    --no-assign-ip
```

踏み台サーバーの設定：

```bash
# IAP対応の踏み台サーバー作成
gcloud compute instances create bastion-host \
    --subnet=my-subnet \
    --no-address \
    --tags=iap-access

# IAPファイアウォールルールの作成
gcloud compute firewall-rules create allow-iap-ssh \
    --direction=INGRESS \
    --priority=1000 \
    --network=my-vpc \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=iap-access
```

### このレベルが解決する課題

「データベースをインターネットの脅威から完全に守りたい」「万が一認証情報が漏洩しても、すぐにはアクセスされたくない」そんな要求レベルの高い環境での選択肢です。

### リスク分析：防御できる攻撃と残存する脅威

**防御できる攻撃**
- **Level 2の脅威の大部分**。特に、認証情報が漏洩しただけでは、即座にDBに接続されることはない

**しかし、このような脅威は防げません**
- **手の込んだ攻撃**: 攻撃者がまずIAM認証情報を盗み、それを使ってVPC内のサーバーに侵入し、そこを踏み台としてDBにアクセスするという多段階攻撃は可能です。ただし、難易度は格段に上がります
- **内部からの情報流出**: VPC内部に侵入された場合、そこからインターネットへデータを送信されるリスクは残ります

### このレベルでの認証

- **人間のアクセス**: IAMデータベース認証が必須。IAPによるトンネル認証と、DBへの接続認証の両方がIAMによって守られる
- **アプリケーションのアクセス**: VPC内部のGCEやGKEで稼働するアプリは、インスタンスにアタッチされたサービスアカウントで接続。外部CI/CDからのアクセスはWorkload Identity連携が唯一の安全な選択肢

### 適用場面

- 金融・医療など規制の厳しい業界
- 機密性の高いデータを扱うシステム
- コンプライアンス要件が厳格な環境

## 【Level 4】究極のゼロトラスト：プライベートIP + VPC Service Controls

### 構成概要

VPC Service Controlsによりデータの持ち出しを完全に制御し、ゼロトラストセキュリティモデルを実現します。

```
[セキュリティ境界]
├─ [Cloud SQL (プライベートIP)]
├─ [Cloud Storage]
└─ [その他のリソース]
     ↑
データの出入りを完全制御
```

### 設定方法

```bash
# セキュリティ境界の作成
gcloud access-context-manager perimeters create my-perimeter \
    --title="Production Perimeter" \
    --resources=projects/123456789 \
    --restricted-services=sql-component.googleapis.com,storage-component.googleapis.com

# VPC Service Controls用のアクセスレベルの設定
gcloud access-context-manager levels create corporate_network \
    --title="Corporate Network" \
    --ip-subnetworks=203.0.113.0/24
```

### このレベルが解決する課題

「万が一内部に侵入されても、データの持ち出しだけは絶対に阻止したい」という、最高レベルのセキュリティ要求に応える構成です。ただし、設定の複雑さと運用コストは相応に高くなります。

### リスク分析：防御できる攻撃と残存する脅威

**防御できる攻撃**
- **Level 3の脅威の大部分**。特に、データ漏洩（Exfiltration）という、攻撃の最終目的を阻止できる
- **内部犯行や設定ミスによる意図しないデータの外部送信**

**しかし、このような脅威は防げません**
- **データの破壊・改ざん**: データを外に持ち出すことはできませんが、内部でデータを削除したり、ランサムウェアで暗号化したりすることは可能です。対策としてバックアップが重要になります
- **内部での攻撃拡散**: ひとつのサーバーに侵入された場合、同じセキュリティ境界内の他のサービスに攻撃が広がる可能性があります

### このレベルでの認証

Level 3の認証プラクティスがすべて適用されていることが大前提となります。VPC Service Controlsは、たとえ正規のIAM認証を突破されたとしても、データの持ち出しを防ぐ最後の砦として機能します。

### 適用場面

- 最高レベルの機密データを扱うシステム
- 国家機密・企業秘密に関わるプロジェクト
- 厳格な監査要件がある環境

## まとめ：あなたのプロジェクトに最適なレベルを選ぶ

### 脅威と対策のマトリックス

各レベルがどの脅威に対応できるかを整理してみましょう。

| 脅威             | Level 1 | Level 2 | Level 3 | Level 4 |
| ---------------- | ------- | ------- | ------- | ------- |
| 無差別攻撃       | ✅       | ✅       | ✅       | ✅       |
| パスワード攻撃   | ❌       | ✅       | ✅       | ✅       |
| データ盗聴       | ❌       | ✅       | ✅       | ✅       |
| ネットワーク攻撃 | ❌       | ❌       | ✅       | ✅       |
| 権限昇格攻撃     | ❌       | ❌       | ⚠️       | ✅       |
| データ持ち出し   | ❌       | ❌       | ❌       | ✅       |
| 内部不正         | ❌       | ❌       | ⚠️       | ⚠️       |

### 選択フローチャート

1. **データの機密性は？**
   - 低 → Level 1-2を検討
   - 中 → Level 2-3を検討
   - 高 → Level 3-4を検討

2. **規制・コンプライアンス要件は？**
   - なし → Level 1-2で十分
   - あり → Level 3以上を検討

3. **運用チームのスキルレベルは？**
   - 初級 → Level 1-2から開始
   - 中級 → Level 2-3を検討
   - 上級 → Level 4も選択肢

4. **予算とコストは？**
   - 制約あり → Level 1-2
   - 標準 → Level 2-3
   - 十分 → Level 3-4

### 最適な選択のために

セキュリティは投資です。しかし、無制限に投資できるわけではありません。あなたのプロジェクトの価値、チームのスキル、予算、コンプライアンス要件を天秤にかけて、最適なレベルを選択してください。

重要なのは、最初から完璧を目指すのではなく、要件の変化に応じて段階的にレベルアップしていくことです。Level 1から始めて、必要に応じてLevel 2、Level 3へと進化させていけばよいのです。

「完璧」なセキュリティは存在しませんが、あなたのプロジェクトにとって「最適」なセキュリティレベルは必ず見つけることができます。今日の選択が、明日のビジネスを守る基盤となります。
