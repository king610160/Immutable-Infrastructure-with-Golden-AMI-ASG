# Immutable Infrastructure with Golden AMI & ASG

### 專案簡介
本專案透過 **Packer** 預先編譯好含有 Nginx 服務的 **Golden AMI**，並利用 **Terraform** 部署具備高可用性與自動擴展能力的 **Auto Scaling Group (ASG)**。

### 使用技術
* **Infrastructure as Code:** Terraform
* **Image Management:** Packer, Amazon Machine Image (AMI)
* **Cloud Provider:** AWS (EC2, ASG, ALB, VPC)
* **OS:** Amazon Linux 2023
* **Monitoring:** CloudWatch (Detailed Monitoring)

---

### 系統架構邏輯
此架構確保了當流量激增時，ASG 能在最短時間內透過預建好的 AMI 迅速橫向擴展，無需在啟動時執行緩慢的軟體編譯或安裝過程，實現「開機即服務」。

---

### 核心組件說明

#### 1. Image 構建 (Packer)
使用 Packer 自動化建立 AMI。

```bash
# 初始化
packer init .

# 格式檢查
packer fmt .
packer validate .

# 執行 Packer 構建
packer build nginx-v1.pkr.hcl
```

#### 2. 基礎設施部署 (Terraform)

* **Launch Template:** 引用 Packer 產出的 `image_id`，並開啟 `monitoring { enabled = true }` 以達成 1 分鐘等級的監控精確度。
* **Mixed Instances Policy:** 結合 **On-Demand** (保底) 與 **Spot Instances** (省錢) 的混合策略。
* **Target Tracking Policy:** 設定 CPU 50% 為擴展門檻期。

---

### 關鍵優化紀錄

#### 啟動速度優化 (Scaling Speed)
* **傳統 User Data:** 啟動需約 120-180 秒 (包含系統更新與 Nginx 編譯)。
* **Golden AMI 模式:** 啟動縮短至 **40-60 秒** (僅需等待基礎設施就緒與 ALB 健康檢查)。

#### 零斷線下線策略 (Graceful Shutdown)
透過調整 `deregistration_delay`，將原本預設 300 秒的連線排空時間優化為 30-60 秒，讓節點在縮減 (Scale-in) 時能更迅速且優雅地釋放資源。

---

## Quick start

#### 第一步：產出 AMI
進到 `packer/` 目錄並執行：

```bash
packer init .
packer build .
```

#### 第二步：部署環境
取得 AMI ID 後，透過變數傳入進行部署：

```txt
# 建議在 terraform.tfvars 中指定
custom_ami_id = "ami-xxxxxxxxxxxx"
```

執行部署：

```bash
terraform plan
terraform apply
```

#### 第三步：壓力測試
登入 EC2 並使用工具模擬高負載，觀察 CloudWatch 每分鐘的指標變動：

```bash
# 模擬 2 核 CPU 滿載 5 分鐘
sudo dnf install stress -y
stress --cpu 2 --timeout 300
```

### 關鍵優化紀錄

#### 營運維護建議 (Maintenance)
* **不可變性原則:** 當 Nginx 需要更新或修補漏洞時，應更新 Packer 腳本後重新產出 AMI，並透過 Terraform 的 `instance_refresh` 進行滾動更新，不建議手動更新。
* **資料獨立性:** 若需跨帳號分享 AMI，應執行 **AMI Copy** 以確保目標帳號擁有獨立的 Snapshot 實體，避免來源帳號刪除資源導致單點故障。

#### 未來優化方向
* 導入 **EC2 Image Builder** 建立全自動化的 AMI 生命週期管理流水線。
* 整合 **CloudWatch Logs Agent** 將 Nginx Access Log 持久化至 CloudWatch。