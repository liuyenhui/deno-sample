# Deno Sample 部署指南

面向 Flux GitOps 流水线的 Deno 示例服务：推送代码 → 自动构建多架构镜像 → 更新 `fleet-infra` 清单 → Flux 滚动发布。下文按准备、本地构建、清单管理、CI/CD 与验证顺序说明。

## 1. 准备工作
- 开发环境：安装 Deno、Docker（启用 Buildx/QEMU），可访问 `registry.cn-beijing.aliyuncs.com`。
- Git 仓库：
  - `deno-sample`：应用源码 + GitHub Actions（CI）。
  - `fleet-infra`：Flux GitOps 清单（CD），包含 `apps/deno-sample/`。
- GitHub Secrets（deno-sample 仓库）：
  - `ALIYUN_REGISTRY_USERNAME` / `ALIYUN_REGISTRY_PASSWORD`：Docker 登录阿里云。
- Kubernetes Secret（在 `flux-system` 命名空间）：
  ```bash
  kubectl -n flux-system create secret docker-registry deno-sample-registry \
    --docker-server=registry.cn-beijing.aliyuncs.com \
    --docker-username=<ALIYUN_REGISTRY_USERNAME> \
    --docker-password=<ALIYUN_REGISTRY_PASSWORD>
  ```
  Flux Image Repository 会使用该 Secret 轮询镜像仓库；请勿将真实凭据提交到 Git。

## 2. 本地构建与推送
1. 可选：在本地验证二进制。
   ```bash
   deno compile --allow-net main.ts
   ```
2. 构建并推送多架构镜像到阿里云，保持 `main` 与 `ts-<UTC时间>-<commit>` 标签（CI 亦采用此格式，保证 Flux 能根据时间戳排序）。
  ```bash
  docker buildx build \
     --platform linux/amd64,linux/arm64 \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:main \
     -t registry.cn-beijing.aliyuncs.com/threepeople/deno-sample:ts-$(date -u +'%Y%m%d%H%M%S')-$(git rev-parse --short HEAD) \
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
`fleet-infra/clusters/my-cluster/flux-system/` 新增了三类 CRD：

| 文件 | 资源 | 作用 |
| --- | --- | --- |
| `deno-sample-imagerepository.yaml` | `ImageRepository` | 每分钟使用 `deno-sample-registry` Secret 去 registry 查询所有标签 |
| `deno-sample-imagepolicy.yaml` | `ImagePolicy` | 使用 `ts-YYYYMMDDHHMMSS-<sha>` 标签的时间戳（`filterTags.extract: $ts` + `policy.numerical`）选择最新镜像 |
| `deno-sample-imageupdate.yaml` | `ImageUpdateAutomation` | 检出 GitRepository/flux-system，针对 `apps/deno-sample/deployment.yaml` 应用 Setter，写入最新标签并提交 `chore: update deno-sample image to ...` |

这样 Image Automation 会在集群中自动修改 Git，并由 Flux Kustomization 将新清单同步到集群，实现“CD 追踪镜像仓库”。

## 5. GitHub Actions 自动化（CI）
工作流 `.github/workflows/build-and-push.yaml` 现在只负责构建镜像，不再触碰 Git 清单：

1. Push 到 `main`（非 `github-actions[bot]`）或手动 `workflow_dispatch` 时触发。
2. 生成 `IMAGE_TAG=ts-<UTC时间>-<七位提交>`，并保留 `type=sha` 与 `type=ref` 标签，保持调试友好。
3. 登录阿里云，构建 multi-arch 镜像，推送 `main` + `sha-` + `ts-` 多组标签。
4. 后续由 Flux Image Automation 监听新标签并修改 Git，不需要在 CI 中维护 PAT 或第二次 checkout。

## 6. 自动镜像发布
- 发布路径：推送代码 → CI 推镜像 → ImageRepository 发现 `ts-` 新标签 → ImagePolicy 选中最新标签 → ImageUpdateAutomation 提交 PR（直接推送） → Flux Kustomization 部署 → 新 Pod 自动上线。
- 如需手动回滚，直接在 `apps/deno-sample/deployment.yaml` 把 `image` 换成目标 `ts-` 标签并提交，Image Automation 不会阻止手动编辑。
- 若希望暂停自动更新，可暂时暂停 `ImageUpdateAutomation`（`kubectl suspend imageupdateautomation deno-sample -n flux-system`），或限制 `ImagePolicy` 的匹配模式。

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
   flux get image repository deno-sample -n flux-system
   flux get image policy deno-sample-latest -n flux-system
   flux logs --kind ImageUpdateAutomation --name deno-sample -n flux-system
   ```
   结合 `kubectl describe` 判断是镜像抓取失败、Policy 未匹配到 `ts-` 标签，还是 Git 提交冲突。
