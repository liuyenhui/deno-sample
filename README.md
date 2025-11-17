# Deno Sample 部署指南

## 本地构建
1. **编译本地可执行文件（可选）**
   ```bash
   deno compile --allow-net main.ts
   ```
2. **构建并推送多架构镜像到阿里云（确保 AMD64/ARM64 节点都可拉取）**
   ```bash
   docker buildx build \
     --platform linux/amd64,linux/arm64 \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:main \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:sha-$(git rev-parse --short HEAD) \
     --push .
   ```

## Kubernetes 清单
1. 在 `fleet-infra/apps/deno-sample/` 下编写 Deployment、Service、Ingress 等 YAML，并在目录中添加一个 `kustomization.yaml` 聚合这些资源。
2. Deployment 中 `spec.template.spec.containers[0].image` 指向上文推送的镜像标签（CI 会自动写入 `sha-<commit>` 标签，手动构建时可参考该格式）。

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
1. 工作流位于 `.github/workflows/build-and-push.yaml`，在 `main` 分支有 push 且触发者不是 `github-actions[bot]` 时自动运行，也可在 GitHub UI 中手动触发（`workflow_dispatch`）。
2. 工作流流程：
   - Checkout 代码（带完整 Git 历史），初始化 Buildx/QEMU。
   - 生成 `IMAGE_TAG=sha-<七位提交>`，同时保留 `main` 标签，并通过 `ALIYUN_REGISTRY_USERNAME/ALIYUN_REGISTRY_PASSWORD` 登录阿里云镜像仓库。
   - 构建并推送 `linux/amd64, linux/arm64` 镜像到 `registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:{main, sha-xxxxxxx}`。
   - 自动修改 `fleet-infra/apps/deno-sample/deployment.yaml` 中的镜像标签，提交 `chore: update deno-sample image to <tag>` 到 `main`，以便 Flux 捕获清单差异。
3. 工作流生成的提交作者为 `github-actions[bot]`，后续 push 触发的工作流会因 `if: github.actor != 'github-actions[bot]'` 自动跳过，避免循环构建。
4. 启用前需在仓库 Secrets 中新增 `ALIYUN_REGISTRY_USERNAME` 与 `ALIYUN_REGISTRY_PASSWORD`，对应阿里云镜像仓库的账号。
5. 若仓库里缺少 `fleet-infra/apps/deno-sample/deployment.yaml`（例如只包含应用源码而不包含集群清单），工作流会跳过 “Update Deployment image tag” 与 “Commit manifest update” 步骤，此时需要使用其他方式让集群获取新的镜像标签。

## 自动镜像发布
- 每次推送应用代码时，CI 会产出一个新的 `sha-<commit>` 标签，并立即将 Deployment 更新到该标签；无需手动执行 `kubectl rollout restart`。
- Flux 监控 `fleet-infra/apps/deno-sample/` 清单，一旦发现 Deployment 中的镜像标签发生变化便执行滚动更新。
- 如果需要手动重建历史版本，直接修改 `fleet-infra/apps/deno-sample/deployment.yaml` 的 `image` 字段并提交，或在本地构建时指定任意唯一标签后重复 CI 的更新流程。
