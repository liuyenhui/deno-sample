# Deno Sample 部署指南

## 本地构建
1. **编译本地可执行文件（可选）**
   ```bash
   deno compile --allow-net main.ts
   ```
2. **构建容器镜像**
   ```bash
   docker build -t ghcr.io/liuyenhui/deno-sample:main .
   ```
3. **推送镜像**
   ```bash
   docker push ghcr.io/liuyenhui/deno-sample:main
   ```

## Kubernetes 清单
1. 在 `fleet-infra/apps/deno-sample/` 下编写 Deployment、Service、Ingress 等 YAML，并在目录中添加一个 `kustomization.yaml` 聚合这些资源。
2. Deployment 中 `spec.template.spec.containers[0].image` 指向上文推送的镜像标签（如 `ghcr.io/liuyenhui/deno-sample:main`）。

## Flux Source & Kustomization
1. **GitRepository**
   ```bash
   flux create source git deno-sample \
     --url=https://github.com/liuyenhui/deno-sample.git \
     --branch=main \
     --interval=1m \
     --export > fleet-infra/clusters/remote-master/flux-system/deno-sample-source.yaml
   ```
2. **Kustomization**
   ```bash
   flux create kustomization deno-sample \
     --source=GitRepository/deno-sample \
     --path="./k8s" \
     --target-namespace=default \
     --prune=true \
     --interval=5m \
     --export > fleet-infra/clusters/remote-master/flux-system/deno-sample-kustomization.yaml
   ```
   - `--path` 指向 `deno-sample` 仓库中存放 Kubernetes 清单的目录（如 `k8s/`）。根据实际目录调整。
3. 将生成的 YAML 与 `apps/deno-sample/` 清单一起提交并推送到 `fleet-infra` 仓库。

## 验证部署
1. **确认 Source 和 Kustomization**
   ```bash
   kubectl --context remote-master get gitrepositories.source.toolkit.fluxcd.io -n flux-system
   kubectl --context remote-master get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system
   ```
2. **查看资源状态**
   ```bash
   kubectl --context remote-master get pods -l app=deno-sample
   kubectl --context remote-master get svc deno-sample
   ```
3. 如遇失败，使用 `kubectl describe` 检查 `GitRepository` 与 `Kustomization` 的事件日志。

## GitHub Actions 自动构建
1. 工作流文件位于 `.github/workflows/build-and-push.yaml`，在 `main` 分支有 push 时自动运行，也可在 GitHub UI 里手动触发（`workflow_dispatch`）。
2. 工作流步骤：
   - Checkout 代码、初始化 Buildx。
   - 使用默认的 `GITHUB_TOKEN` 登录 GHCR（需确保仓库拥有 Packages 写权限）。
   - 根据分支与提交 SHA 生成镜像标签，并使用 `docker/build-push-action` 构建与推送镜像到 `ghcr.io/liuyenhui/deno-sample`。
3. 首次启用时可在仓库的 **Settings → Actions → General** 中允许 GitHub Actions，并在 **Settings → Packages** 确认 `GITHUB_TOKEN` 对 GHCR 拥有 `write:packages` 权限。
