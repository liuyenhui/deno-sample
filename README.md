# Deno Sample 部署指南

面向 Flux GitOps 流水线的 Deno 示例服务：推送代码 → 自动构建多架构镜像 → Flux Image Automation 自动写回 `fleet-infra` → Flux Kustomization 滚动发布。下文按准备、本地构建、清单管理、CI/CD、Image Automation 与排障顺序说明。

## 1. 准备工作
- **开发环境**：安装 Deno、Docker（开启 Buildx/QEMU），并确保能访问 `registry.cn-beijing.aliyuncs.com`。若本地访问 API Server 需要代理，记得为 CLI 设置 `HTTPS_PROXY=/ NO_PROXY=`。
- **Git 仓库**：
  - `deno-sample`：应用源码 + GitHub Actions（CI）。
  - `fleet-infra`：Flux GitOps 清单（CD），包含 `apps/deno-sample/` 与 `clusters/my-cluster/`。
- **GitHub Secrets（deno-sample 仓库）**：
  - `ALIYUN_REGISTRY_USERNAME` / `ALIYUN_REGISTRY_PASSWORD`：Docker 登录阿里云的凭据。
- **Kubernetes Secret（flux-system 命名空间）**：供 Flux ImageRepository 拉取阿里云镜像。
  ```bash
  kubectl -n flux-system create secret docker-registry deno-sample-registry \
    --docker-server=registry.cn-beijing.aliyuncs.com \
    --docker-username=<ALIYUN_REGISTRY_USERNAME> \
    --docker-password=<ALIYUN_REGISTRY_PASSWORD>
  ```
  （如已存在，用 `kubectl apply` 更新即可；切勿将真实账号写入 Git。）
- **Flux 组件**：`gotk-components.yaml` 需包含 `image-reflector-controller` 与 `image-automation-controller`。因为集群走内网代理，`clusters/my-cluster/flux-system/kustomization.yaml` 已使用 Kustomize patch 给所有 Flux Deployment 注入：
  ```yaml
  env:
    - name: HTTPS_PROXY
      value: http://v2ray-client-service.default.svc.cluster.local:1087
    - name: NO_PROXY
      value: .cluster.local.,.cluster.local,.svc
  ```
  若代理地址改变，请同步修改 patch；否则 Flux 无法从 GHCR 拉取控制器镜像。
- **Flux Git 访问**：`flux-system` Secret 中保存的 SSH key 必须拥有 `liuyenhui/fleet-infra` 仓库的写权限（Deploy Key → Allow write access），否则 ImageUpdateAutomation 无法 push 变更。若需更换密钥：
  1. `ssh-keygen -t ed25519 -f ~/.ssh/flux-fleet-infra -C "flux-image-automation"`
  2. 将 `~/.ssh/flux-fleet-infra.pub` 添加到仓库 Deploy Keys（勾选 **Allow write access**）。
  3. 更新集群 Secret：
     ```bash
     ssh-keyscan github.com > /tmp/known_hosts
     kubectl -n flux-system create secret generic flux-system --dry-run=client -o yaml \
       --from-file=identity=$HOME/.ssh/flux-fleet-infra \
       --from-file=identity.pub=$HOME/.ssh/flux-fleet-infra.pub \
       --from-file=known_hosts=/tmp/known_hosts \
       | kubectl apply -f -
     ```
  4. `flux reconcile source git flux-system -n flux-system && flux reconcile kustomization flux-system -n flux-system`

## 2. 本地构建与推送
1. 可选：在本地验证二进制。
   ```bash
   deno compile --allow-net main.ts
   ```
2. 构建并推送多架构镜像到阿里云，保持 `main` 与 `ts-<上海时间>-<commit>` 标签（CI 同样采用此格式，便于 ImagePolicy 根据时间戳排序）。
   ```bash
   docker buildx build \
     --platform linux/amd64,linux/arm64 \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:main \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:ts-$(TZ='Asia/Shanghai' date +'%Y%m%d%H%M%S')-$(git rev-parse --short HEAD) \
     --push .
   ```

## 3. Kubernetes/Flux 清单
1. 在 `fleet-infra/apps/deno-sample/` 中维护 Deployment、Service、Ingress，并用 `kustomization.yaml` 聚合。
2. Deployment 的容器镜像行添加 `{"$imagepolicy": "flux-system:deno-sample-latest"}` Setter 注释，允许 Flux 自动改写。例如：
   ```yaml
   image: registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:main # {"$imagepolicy": "flux-system:deno-sample-latest"}
   ```
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

## 4. Flux Image Automation
`fleet-infra/clusters/my-cluster/flux-system/` 需要以下资源，并由顶层 `kustomization.yaml` 引入：

| 文件 | 资源 | 作用 |
| --- | --- | --- |
| `deno-sample-imagerepository.yaml` | `ImageRepository` | 每分钟使用 `deno-sample-registry` Secret 去 registry 查询所有标签 |
| `deno-sample-imagepolicy.yaml` | `ImagePolicy` | 使用 `ts-YYYYMMDDHHMMSS-<sha>` 标签的时间戳（`filterTags.extract: $ts` + `policy.numerical`）选择最新镜像 |
| `deno-sample-imageupdate.yaml` | `ImageUpdateAutomation` | 检出 `GitRepository/flux-system` 的 `main` 分支，针对 `apps/deno-sample/` 应用 Setter，写入最新标签并提交 `chore: update deno-sample image` |

这样 Image Automation 会在集群中自动修改 Git，并由 Flux Kustomization 将新清单同步到集群，实现“CD 追踪镜像仓库”。

## 5. GitHub Actions 自动化（CI）
CI 工作流位于 `.github/workflows/build-and-push.yaml`，只负责构建镜像，不再改写 Git 清单：

1. Push 到 `main`（非 `github-actions[bot]`）或手动 `workflow_dispatch` 时触发。
2. 生成 `IMAGE_TAG=ts-<上海时间>-<七位提交>`，并保留 `type=sha` 与 `type=ref` 标签，保持调试友好。
3. 登录阿里云，构建 multi-arch 镜像，推送 `main` + `sha-` + `ts-` 多组标签。
4. 后续由 Flux Image Automation 监听新标签并修改 Git，不需要在 CI 中维护 PAT 或第二次 checkout。

## 6. 自动镜像发布与注意事项
- **整体流程**：推送代码 → CI 推镜像 → ImageRepository 发现 `ts-` 新标签 → ImagePolicy 选出最新标签 → ImageUpdateAutomation 提交到 `fleet-infra` → Flux Kustomization 部署 → 新 Pod 自动上线。
- **代理提示**：所有 Flux 控制器（含 image-reflector & image-automation）都通过 `v2ray-client-service` 访问外部镜像/仓库，若代理地址或端口变化，必须更新 `clusters/my-cluster/flux-system/kustomization.yaml` 中的 patch，否则新组件拉取镜像会失败。
- **写权限**：ImageUpdateAutomation 会以 `fluxcd-bot` 身份直接 push 到 `liuyenhui/fleet-infra/main`，需保证 Deploy Key 或 Secret 中的凭据拥有写权限。
- **暂停/回滚**：
  - 手动回滚：编辑 `apps/deno-sample/deployment.yaml` 中的 `image`，提交后 Flux 会按照 Git 状态恢复。
  - 暂停自动更新：`kubectl suspend imageupdateautomation deno-sample -n flux-system`；恢复时执行 `kubectl resume ...`。

## 7. 验证与故障排查
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
3. 如滚动失败，可使用：
   ```bash
   flux get images repository deno-sample -n flux-system
   flux get images policy deno-sample-latest -n flux-system
   flux get images update deno-sample -n flux-system
   flux logs --namespace flux-system --kind ImageUpdateAutomation --name deno-sample
   ```
   结合 `kubectl describe` 判断是镜像抓取失败、Policy 未匹配到 `ts-` 标签，还是 Git 提交冲突。
- 若 CLI 版本较旧，上述命令中的 `images` 关键字不可省略（例如 `flux get images update ...`），并确保在缺省命名空间外执行时加 `-n flux-system`。
