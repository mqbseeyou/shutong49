# 构建目标平台（默认 linux/amd64；可覆盖：docker build --platform linux/arm64）
# Node 阶段用 TARGETPLATFORM（与 python 阶段一致）；Windows 上 BUILDPLATFORM 常为 windows/amd64，官方 node 无此平台会 not found。
ARG TARGETPLATFORM=linux/amd64
# 可覆写基础镜像（用于无法直连 Docker Hub 的环境）
ARG NODE_IMAGE=node:20-bookworm-slim
ARG PYTHON_IMAGE=python:3.12-slim
ARG INSTALL_APP_NODE_EXTRAS=0
ARG PREWARM_NPX_MCP=0
# ========== 阶段 1：构建前端（用 Debian 版 Node，便于阶段 2 复用，避免 apt 拉取 node/npm 失败）==========
FROM --platform=$TARGETPLATFORM ${NODE_IMAGE} AS frontend-builder
WORKDIR /app/frontend

COPY frontend/package.json frontend/package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci 2>/dev/null || npm install
COPY frontend/ ./
# 仅执行 vite build，避免 vue-tsc 与 TypeScript 版本不兼容导致构建失败；类型检查可在本地或 CI 做
RUN ./node_modules/.bin/vite build

# ========== 阶段 2：运行后端并托管前端静态 ==========
FROM --platform=$TARGETPLATFORM ${PYTHON_IMAGE}
ARG INSTALL_APP_NODE_EXTRAS=0
ARG PREWARM_NPX_MCP=0
WORKDIR /app

# 运行期/Skill 沙箱基础工具：
# - curl: 健康检查
# - git/openssh-client/ca-certificates: skill git 导入（clone/fetch/pull）
# - bash 与常用 coreutils/jq/rg/tree/zip 等：run_skill_script 执行 .sh/.bash 与通用脚本
# - ffmpeg/imagemagick/poppler/tesseract/fonts: 文档、图片与 OCR 类 Skill 的基础能力
# Node/npm 从 frontend-builder 复制，避免 apt 拉取大量 node-* 包导致网络超时/失败
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils curl dnsutils file findutils gawk git gnupg grep gzip jq less make nano \
    openssh-client patch procps ripgrep sed tar tini tree unzip vim-tiny wget xz-utils zip \
    ffmpeg imagemagick poppler-utils tesseract-ocr fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制 Node/npm/npx 及完整 lib（运行期懒加载 npx MCP 时仍需要）
COPY --from=frontend-builder /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/
COPY --from=frontend-builder /usr/local/lib /usr/local/lib
# npx 及其依赖（@npmcli/* 等）在 npm 的 node_modules 内，需让 Node 能解析
ENV NODE_PATH=/usr/local/lib/node_modules:/usr/local/lib/node_modules/npm/node_modules
# node:20-bookworm-slim 中 npx 依赖 ../lib/cli.js 与 ./npm-cli.js（相对 /usr/local/bin），补符号链接。
# Skill 脚本默认运行在独立 sandbox 镜像中；app 镜像默认不再预装 yarn/pnpm/tsx 等额外 Node 工具。
RUN ln -sf /usr/local/lib/node_modules/npm/lib/cli.js /usr/local/lib/cli.js \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm-cli.js \
    && if [ "$INSTALL_APP_NODE_EXTRAS" = "1" ]; then npm install -g yarn pnpm typescript tsx; fi

# 后端依赖与代码（保持 backend 目录结构，便于与本地一致）
# 把 requirements 单独拎出来，避免改业务代码就重装全部依赖
COPY backend/requirements.txt ./backend/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r backend/requirements.txt \
      beautifulsoup4 lxml markdown matplotlib numpy pandas pillow pymupdf python-pptx requests rich tqdm
COPY backend/ ./backend/

# 前端构建产物
COPY --from=frontend-builder /app/frontend/dist ./frontend_dist

# 环境变量：静态目录供 main 挂载；工作目录与 Python 路径
# 说明：config 随镜像打包；用户数据（含每用户 skills）通常挂载 /app/data
ENV STATIC_DIR=/app/frontend_dist
ENV PYTHONPATH=/app/backend
ENV MCP_CONFIG_PATH=/app/backend/config/mcp_servers.json
ENV APP_SETTINGS_PATH=/app/backend/config/app_settings.json
ENV SESSIONS_DIR=/app/backend/data/sessions
ENV AGENT_OUTPUTS_DIR=/app/backend/data/agent-outputs

# 默认端口
EXPOSE 8000

# 可选预拉取 npx MCP 包；默认关闭，避免普通打包反复下载临时 npm 包。
# file-reader 已是 Python 实现，不再需要预拉取 @modelcontextprotocol/server-filesystem。
# Playwright 能力由独立 Skill sandbox 镜像提供，app 镜像不预拉取 @playwright/mcp。
WORKDIR /app/backend
RUN --mount=type=cache,target=/root/.npm \
    mkdir -p /app/data/sessions /app/data/agent-outputs /app/config \
    && if [ "$PREWARM_NPX_MCP" = "1" ]; then \
      timeout 30 npx -y @amap/amap-maps-mcp-server 2>/dev/null || true; \
    else \
      echo "Skipping npx MCP package prewarm"; \
    fi

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
