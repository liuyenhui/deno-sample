# Deno Sample 部署指南

面向 Flux GitOps 流水线的 Deno 示例服务：推送代码 → 自动构建多架构镜像 → 更新 `fleet-infra` 清单 → Flux 滚动发布。下文按准备、本地构建、清单管理、CI/CD 与验证顺序说明。

## 1. 准备工作
- 安装 Deno、Docker（启用 Buildx/QEMU），并可访问 `registry.cn-beijing.aliyuncs.com`。
- 拥有两个 Git 仓库：
  - `deno-sample`：应用源码与 GitHub Actions 工作流。
  - `fleet-infra`：Flux 管理的 Kubernetes 清单，目录结构中包含 `apps/deno-sample/`。
- 在 `deno-sample` 仓库的 **Settings → Secrets and variables → Actions** 中配置：
  - `ALIYUN_REGISTRY_USERNAME` / `ALIYUN_REGISTRY_PASSWORD`：阿里云镜像仓库凭据。
  - `FLEET_INFRA_GIT_TOKEN`：任选的 PAT（`repo` 权限即可），用于检出并推送 `fleet-infra`。若暂未配置，该工作流仍会构建/推送镜像，但不会自动改写 Flux 清单，需要手动触发发布。

## 2. 本地构建与推送
1. 可选：在本地验证二进制。
   ```bash
   deno compile --allow-net main.ts
   ```
2. 构建并推送多架构镜像到阿里云，保持 `main` 与 `sha-<commit>` 两个标签（与 CI 保持一致）。
   ```bash
   docker buildx build \
     --platform linux/amd64,linux/arm64 \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:main \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:sha-$(git rev-parse --short HEAD) \
     --push .
   ```

## 3. Kubernetes/Flux 清单
1. 在 `fleet-infra/apps/deno-sample/` 中维护 Deployment、Service、Ingress，并用 `kustomization.yaml` 聚合。
2. Deployment 的 `spec.template.spec.containers[0].image` 应指向当前镜像标签。CI 会自动填入 `sha-<commit>`；如需手动编辑，保持相同格式即可。
3. 通过 Flux 创建 GitRepository/Kustomization 资源示例：
   ```bash
   flux create source git deno-sample \
     --url=https://github.com/liuyenhui/deno-sample.git \
     --branch=main \
     --interval=1m \
     --export > fleet-infra/clusters/remote-master/flux-system/deno-sample-source.yaml

   flux create kustomization deno-sample \
     --source=GitRepository/deno-sample \
     --path="./k8s" \
     --target-namespace=default \
     --prune=true \
     --interval=5m \
     --export > fleet-infra/clusters/remote-master/flux-system/deno-sample-kustomization.yaml
   ```
   - `--path` 指向 `deno-sample` 仓库里存放 Kubernetes 清单的目录（如 `k8s/`），可按实际路径调整。
4. 将上述 YAML 与 `apps/deno-sample/` 清单一并提交到 `fleet-infra`。

## 4. GitHub Actions 自动化
工作流位于 `.github/workflows/build-and-push.yaml`，在 `main` 分支有 push（且触发者不是 `github-actions[bot]`）时触发，也支持 `workflow_dispatch` 手动执行。核心步骤：

1. Checkout `deno-sample` 仓库（保留完整历史），设置 `IMAGE_TAG=sha-<七位提交>`。
2. 初始化 Buildx/QEMU，登录阿里云镜像仓库，构建并推送 `linux/amd64` 与 `linux/arm64` 镜像到 `registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:{main, sha-xxxxxxx}`。
3. 使用第二次 `actions/checkout` 拉取 `liuyenhui/fleet-infra`（或通过 `FLEET_INFRA_REPO/FLEET_INFRA_BRANCH/FLEET_INFRA_PATH` 覆盖），更新 `apps/deno-sample/deployment.yaml` 的镜像标签，并以 `github-actions[bot]` 身份推送 `chore: update deno-sample image to <tag>` 提交。若未提供 `FLEET_INFRA_GIT_TOKEN`，此步骤会被自动跳过。
4. 由于工作流会提交回 `deno-sample` 仓库，后续由 `github-actions[bot]` 触发的 push 会被 `if: github.actor != 'github-actions[bot]'` 自动忽略，避免循环构建。

## 5. 自动镜像发布
- 每次 push 应用代码 → CI 推送新镜像并更新 `fleet-infra` Deployment → Flux 发现清单差异后滚动更新，无需人工执行 `kubectl rollout restart`。
- 如需回滚或发布特定版本，可直接修改 `fleet-infra/apps/deno-sample/deployment.yaml` 中的镜像标签并提交；Flux 会按 GitOps 机制生效。
- 如果暂时没有 `FLEET_INFRA_GIT_TOKEN`，可以在镜像推送后手动更新 `fleet-infra` 仓库的 Deployment 标签，或执行 `flux reconcile kustomization deno-sample -n flux-system` 强制拉取最新 Git 状态。

## 6. 验证与故障排查
1. 检查 Flux Source/Kustomization：
   ```bash
   kubectl --context remote-master get gitrepositories.source.toolkit.fluxcd.io -n flux-system
   kubectl --context remote-master get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system
   ```
2. 观察应用资源状态：
   ```bash
   kubectl --context remote-master get pods -l app=deno-sample
   kubectl --context remote-master get svc deno-sample
   ```
3. 如滚动失败，使用 `kubectl describe` 或 `flux logs --kind Kustomization --name deno-sample -n flux-system` 查看事件；若镜像未更新，确认 CI 是否写入新的 `sha-` 标签以及 `fleet-infra` 是否已合并最新提交。
