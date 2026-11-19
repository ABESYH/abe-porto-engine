# Self-Hosted AI Container Build Pipeline (Reference Archive)

[Bahasa Indonesia](#bahasa-indonesia) • [English](#english) • [中文](#中文)

---

## Bahasa Indonesia

Arsitektur *2-layer container build* yang dijalankan menggunakan **Self-Hosted GitHub Actions Runner** di atas **GCP Compute Engine VM** dengan **Persistent Disk** sebagai *build cache* Docker:

1. **`base/Dockerfile` (`workflows/build-base.yml`):** Membungkus *runtime* CUDA dan *model weights* berukuran puluhan GB (menggunakan `aria2c` paralel) ke dalam image `ai-engine-base`.
2. **`worker/Dockerfile` (`workflows/build-worker.yml`):** Mewarisi `ai-engine-base` dan hanya membangun lapisan operasional ringan, sehingga pembaruan *worker* hanya mengunggah *delta layer* (~5 MB) ke registry dalam hitungan detik.

> **Catatan:**
> - Direktori ini berfokus penuh pada arsitektur *containerization*, optimasi *build cache*, dan *self-hosted runner* di GCP (berjalan pada *private runner* `gcp-gpu-builder` di produksi).
> - Seluruh kode internal mesin inferensi AI, model spesifik, dan konfigurasi dihilangkan untuk menjaga kerahasiaan aset bisnis SaaS.

---

## English

A 2-layer container build architecture executed via a **Self-Hosted GitHub Actions Runner** on a **GCP Compute Engine VM** with an attached **Persistent Disk** as Docker build cache:

1. **`base/Dockerfile` (`workflows/build-base.yml`):** Bakes the CUDA runtime and multi-gigabyte model weights (via parallel `aria2c`) into `ai-engine-base`.
2. **`worker/Dockerfile` (`workflows/build-worker.yml`):** Inherits from `ai-engine-base` and builds only the lightweight operational layer, allowing updates to push only a ~5 MB delta layer to the registry in seconds.

> **Notes:**
> - This directory focuses strictly on containerization architecture, build cache optimization, and self-hosted GCP runner automation (`gcp-gpu-builder` in production).
> - Internal AI inference application code, specific model artifacts, and confidential details are omitted to protect proprietary SaaS IP.

---

## 中文

基于 **GCP Compute Engine VM** 部署 **自托管 GitHub Actions Runner**，并挂载 **Persistent Disk** 作为 Docker 构建缓存的双层容器构建架构：

1. **`base/Dockerfile` (`workflows/build-base.yml`)：** 使用并行 `aria2c` 将 CUDA 运行时环境与数十 GB 级模型权重预打包至 `ai-engine-base` 基础镜像。
2. **`worker/Dockerfile` (`workflows/build-worker.yml`)：** 继承 `ai-engine-base` 并仅构建轻量级运维启动层，使代码更新只需向镜像仓库推送约 ~5 MB 的增量层，实现秒级交付。

> **说明：**
> - 本目录专注于展示容器分层架构、构建缓存优化以及 GCP 自托管 Runner 自动化能力（原生产环境运行于私有 Runner `gcp-gpu-builder`）。
> - 为保护商业资产，内部 AI 推理业务代码、具体模型名称及供应商细节均已省略。